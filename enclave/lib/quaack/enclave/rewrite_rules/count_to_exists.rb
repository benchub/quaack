# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "count_to_exists/counted"
require_relative "or_to_union/arms"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' count_to_exists. A query that asks whether a row has
      # any match in another table often counts the matches:
      #
      #   SELECT c.* FROM customers c WHERE (SELECT count(*) FROM orders o WHERE o.customer_id = c.id) > 0
      #
      # which reads every match to count them, when the first one settles
      # it. EXISTS asks just that, so Postgres can stop at the first match,
      # or run it as a semi-join:
      #
      #   SELECT c.* FROM customers c WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id)
      #
      # A count is never NULL and never below 0, so count > 0, count >= 1,
      # and count <> 0 are each true exactly when some row matches, and
      # count = 0, count <= 0, and count < 1 exactly when none does, which
      # is NOT EXISTS. The same holds with the count on the right, as in
      # 0 < (...). count(o.x) counts the matching rows whose o.x isn't NULL,
      # so it becomes an EXISTS with o.x IS NOT NULL added to the
      # subquery's WHERE.
      #
      # QUAACK makes every constant a placeholder before the rules run, so
      # the rule asks the literal oracle whether the placeholder holds 0, or
      # 1, as the operator needs (Literals#holds?). The rewrite drops the
      # placeholder and writes no constant but EXISTS's SELECT 1. That's
      # sound only if every literal set gives the placeholder the value the
      # oracle saw, and each does: literals picks a value only for a
      # placeholder compared with a plain table column, so one compared
      # with a subquery keeps its slow literal in every set (see LiteralSet,
      # unsupported_shape).
      #
      # Neither side of the comparison is NULL, so it's only ever true or
      # false, and so is EXISTS. That makes every position safe: a WHERE, a
      # select list, a CASE, a HAVING, under an OR or a NOT, in a subquery,
      # a CTE, or a UNION arm. Every copy of a comparison is rewritten
      # alike, so copies that Postgres needs to match, as in a select list
      # and its GROUP BY, still do.
      #
      # It gives one rewrite, with every count it can rewrite rewritten,
      # nested ones too. It rests on no catalog fact, so it states none.
      #
      # It's conservative. It rewrites a comparison only when all of this
      # holds:
      #
      # - Nothing in the statement could call a volatile function
      #   (Catalog#calls_volatile?). EXISTS stops at the first match, and a
      #   semi-join runs the subquery's conditions in another order, so a
      #   volatile call would run another number of times. That check
      #   refuses what it can't read, so the statement is one SELECT.
      # - The operator is =, <>, <, <=, >, or >=, bare or pg_catalog's, as
      #   in OPERATOR(pg_catalog.>). A bare one is pg_catalog's, since
      #   qualify writes another schema's with its schema. One side is a
      #   scalar subquery, and the other a placeholder: not a cast of one,
      #   a column, or an expression.
      # - With the count on the left, the oracle says the placeholder is 0
      #   for >, <>, =, and <=, and 1 for >= and <. It compares them as
      #   the placeholder's own type, as the query compares the count, so
      #   0.0 is 0 and 0.5 is neither.
      # - The subquery is a count the rule can read (see Counted).
      # - No GROUP BY holds the subquery bare (see grouped_bare?).
      # - Nothing in the subquery's FROM or WHERE can raise on some rows
      #   (see raises?). It's judged with any count inside it already
      #   rewritten.
      class CountToExists
        # For each operator, with the count on its left: the value the
        # placeholder must hold, and whether the test asks that some row
        # matches (EXISTS) or that none does (NOT EXISTS).
        TESTS = { ">" => [0, true], ">=" => [1, true], "<>" => [0, true],
                  "=" => [0, false], "<=" => [0, false], "<" => [1, false] }.freeze
        # Each operator with the count on its right.
        FLIPPED = { ">" => "<", ">=" => "<=", "<>" => "<>", "=" => "=", "<=" => ">=", "<" => ">" }.freeze

        # One comparison to rewrite: the Node it's in, the count's SubLink,
        # the Counted::Count, and whether it becomes EXISTS or NOT EXISTS.
        Test = Data.define(:node, :link, :count, :exists)

        def name = "count_to_exists"

        def description
          "A count subquery compared so that it asks only whether any row matches, as count(*) > 0 or " \
            "count(*) = 0 does, becomes EXISTS or NOT EXISTS."
        end

        def rewrites(parse, catalog, literals = nil)
          return [] unless literals

          tree = Deparse.copy(parse.tree)
          tests = tests(tree, catalog, literals)
          return [] if tests.empty? || catalog.calls_volatile?(Deparse.faithfully(tree))

          # Inner comparisons first, so an outer one's copy of its subquery
          # holds their rewrites, and is judged with them.
          replaced = tests.reverse.filter_map { |test| exists_of(test, catalog)&.tap { replace!(test, it) } }
          replaced.empty? ? [] : [Rewrite.new(tree:, assumptions: [])]
        end

        private

        # The Test node is, or nil.
        def test(node, catalog, literals)
          link, param, operator = compared(node.a_expr) if node.node == :a_expr
          count = Counted.read(link, catalog) if link
          return unless count

          value, exists = TESTS.fetch(operator)
          Test.new(node:, link:, count:, exists:) if literals.holds?("$#{param.number} = #{value}")
        end

        # The subquery's SubLink, the placeholder's ParamRef, and the
        # operator as it reads with the count on its left, or nil.
        def compared(expr)
          operator = operator(expr)
          left = expr.lexpr
          right = expr.rexpr
          if operator.nil? then nil
          elsif left.node == :sub_link && right.node == :param_ref then [left.sub_link, right.param_ref, operator]
          elsif right.node == :sub_link && left.node == :param_ref
            [right.sub_link, left.param_ref, FLIPPED.fetch(operator)]
          end
        end

        # The comparison's operator, if it's one of TESTS, bare or
        # pg_catalog's, or nil.
        def operator(expr)
          return unless expr.kind == :AEXPR_OP

          names = expr.name.map { it.string&.sval }
          names = names.drop(1) if names.size == 2 && names.first == "pg_catalog"
          names.first if names.size == 1 && TESTS.key?(names.first)
        end

        # EXISTS of a copy of the subquery, or nil when its conditions could
        # raise where the count's don't (see raises?).
        def exists_of(test, catalog)
          link = PgQuery::SubLink.decode(PgQuery::SubLink.encode(test.link))
          return if raises?(link.subselect.select_stmt, catalog)

          Counted.exists!(link.subselect.select_stmt, test.count)
          link.sub_link_type = :EXISTS_SUBLINK
          link
        end

        # Puts link, or NOT link, in the comparison's place.
        def replace!(test, link)
          if test.exists
            test.node.sub_link = link
          else
            test.node.bool_expr = PgQuery::BoolExpr.new(boolop: :NOT_EXPR, args: [PgQuery::Node.new(sub_link: link)])
          end
        end

        # Whether the subquery's FROM or WHERE holds anything that can raise
        # on some rows, such as a cast (see OrToUnion::Arms.raises?). The
        # count runs its conditions only on the rows its plan reads: for a
        # correlated count, a SubPlan reads those that match the correlation,
        # and any count may read only those an index finds. EXISTS or NOT
        # EXISTS can run as a semi-join, an anti-join, a hashed SubPlan, or a
        # seq scan, which runs them on rows the count never reads.
        def raises?(select, catalog)
          [select.from_clause, select.where_clause].any? { OrToUnion::Arms.raises?(it, catalog) }
        end

        # Whether a GROUP BY holds a copy of the test's subquery that isn't
        # itself a test's, as in GROUP BY (SELECT count(*) ...). A
        # comparison in the select list then reads the grouped count, and
        # as EXISTS, it would read a subquery the GROUP BY doesn't hold, so
        # the query wouldn't prepare.
        # Every Test in tree, but those grouped_bare? refuses.
        def tests(tree, catalog, literals)
          found = nodes(tree).filter_map { test(it, catalog, literals) }
          found.reject { grouped_bare?(it, tree, found) }
        end

        def grouped_bare?(test, tree, tests)
          wanted = located_nowhere(test.link)
          Tree.find_all(tree, PgQuery::SelectStmt).flat_map(&:group_clause).any? do |item|
            Tree.find_all(item, PgQuery::SubLink).any? do |link|
              tests.none? { it.link.equal?(link) } && located_nowhere(link) == wanted
            end
          end
        end

        def located_nowhere(link) = Deparse.copy(link).tap { Deparse.clear_locations(it) }

        # Every Node in node, in tree order, each before those inside it.
        def nodes(node, found = [])
          case node
          when Google::Protobuf::RepeatedField then node.each { nodes(it, found) }
          when PgQuery::Node
            found << node
            nodes(node.inner, found)
          when Google::Protobuf::MessageExts then node.class.descriptor.each { nodes(it.get(node), found) }
          end
          found
        end
      end
    end
  end
end
