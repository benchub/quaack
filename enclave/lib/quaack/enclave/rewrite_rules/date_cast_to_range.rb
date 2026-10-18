# frozen_string_literal: true

require "pg_query"
require_relative "rewrite"
require_relative "../deparse"
require_relative "count_to_exists/counted"
require_relative "date_cast_to_range/bounds"
require_relative "implied_predicate_removal/containers"
require_relative "tree"

module Quaack
  module Enclave
    module RewriteRules
      # DESIGN.md's rewrite-rules' date_cast_to_range. A query for one day's
      # rows often casts a timestamp column to a date:
      #
      #   SELECT o.id FROM orders o WHERE o.created_at::date = $1
      #
      # The cast hides the column from a btree on it, so Postgres reads
      # every row. The same test, written as a half-open range on the
      # column, can use the btree:
      #
      #   SELECT o.id FROM orders o WHERE o.created_at >= $1::date AND o.created_at < $1::date + 1
      #
      # ts::date is the day ts falls on, so ts::date = d holds exactly when
      # d <= ts < d + 1, comparing ts with each day's midnight. In the same
      # way, >= d is ts >= d, > d is ts >= d + 1, < d is ts < d, <= d is
      # ts < d + 1, and BETWEEN d1 AND d2 is ts >= d1 AND ts < d2 + 1. For a
      # timestamptz, both the cast and the comparison with a date read the
      # session's TimeZone, so they find the same midnights, DST days
      # included. An infinite ts casts to an infinite date, and compares
      # with every finite day as it did. Both forms are NULL when ts or d
      # is, and otherwise true or false alike.
      #
      # QUAACK makes every constant a placeholder before the rules run, so
      # the rule asks the literal oracle (Literals#holds?) that each day is
      # finite, and that it and the day after it convert to timestamp and
      # timestamptz, so the rewrite can't raise where the original doesn't.
      # The rewrite writes the placeholder, cast to date, and the 1 it adds.
      # That's sound only if every literal set gives the placeholder the
      # value the oracle saw, and each does: literals picks a value only for
      # a placeholder compared with a plain table column, so one compared
      # with a cast of a column keeps its slow literal in every set (see
      # LiteralSet, unsupported_shape).
      #
      # It gives one rewrite, with every comparison it can rewrite
      # rewritten. It rests on no catalog fact, so it states none.
      #
      # It's conservative. It rewrites a comparison only when all of this
      # holds:
      #
      # - It's a top-level conjunct of a WHERE or an inner join's ON, of any
      #   SELECT in the statement.
      # - The operator is =, <, <=, >, or >=, bare or pg_catalog's, or it's
      #   BETWEEN, not NOT BETWEEN or SYMMETRIC.
      # - One side is col::date, CAST(col AS date), or date(col), the type
      #   bare or pg_catalog's, where col is a column of a plain table in
      #   that SELECT's FROM (see CountToExists::Counted.table_column) of
      #   type timestamp or timestamptz itself, not a domain.
      # - Each other side is a placeholder, bare or cast to date. Redaction
      #   types a bare one unknown, which Postgres types date there, or a
      #   number or a boolean, which no date compares with, so the query
      #   fails as it is.
      class DateCastToRange
        TYPES = ["timestamp without time zone", "timestamp with time zone"].freeze
        DATE = [["date"], %w[pg_catalog date]].freeze
        # For each operator, with the cast on its left: the lower bound
        # (ts >=) and the upper bound (ts <), each the day itself (:day),
        # the day after it (:next), or none.
        BOUNDS = { "=" => %i[day next], ">=" => [:day, nil], ">" => [:next, nil],
                   "<" => [nil, :day], "<=" => [nil, :next] }.freeze
        FLIPPED = { "=" => "=", ">=" => "<=", ">" => "<", "<" => ">", "<=" => ">=" }.freeze

        def name = "date_cast_to_range"

        def description
          "A timestamp column cast to date and compared with a date becomes a range on the column."
        end

        def rewrites(parse, catalog, literals = nil)
          return [] unless literals

          tree = Deparse.copy(parse.tree)
          changed = Tree.find_all(tree, PgQuery::SelectStmt).map { rewritten?(it, catalog, literals) }.any?
          changed ? [Rewrite.new(tree:, assumptions: [])] : []
        end

        private

        def rewritten?(select, catalog, literals)
          joins = select.from_clause.flat_map { Tree.joins(it) }.select { it.jointype == :JOIN_INNER && it.quals }
          ons = joins.map { ImpliedPredicateRemoval::OnContainer.new(it) }
          (ons + [ImpliedPredicateRemoval::WhereContainer.new(select)]).map do |container|
            replaced?(container, select, catalog, literals)
          end.any?
        end

        def replaced?(container, select, catalog, literals)
          changed = false
          conditions = container.conditions.flat_map do |condition|
            range = range(condition, select, catalog, literals)
            changed ||= !range.nil?
            range || [condition]
          end
          container.conditions = conditions if changed
          changed
        end

        # The conjuncts that replace condition, or nil.
        def range(condition, select, catalog, literals)
          expr = condition.a_expr if condition.node == :a_expr
          column, lower, upper = bounds(expr) if expr
          return unless column && column?(column, select, catalog)

          days = [lower, upper].compact.map(&:last)
          return unless days.all? { day?(it, literals) }

          [Bounds.bound(">=", column, lower), Bounds.bound("<", column, upper)].compact
        end

        # [the cast's ColumnRef, [:day or :next, the lower day's Node] or
        # nil, the same for the upper day], or nil.
        def bounds(expr)
          case expr.kind
          when :AEXPR_OP then compared(expr)
          when :AEXPR_BETWEEN
            low, high = expr.rexpr.list.items.to_a
            column = cast_column(expr.lexpr)
            [column, [:day, low], [:next, high]] if column
          end
        end

        def compared(expr)
          operator = operator(expr)
          return unless operator

          column, day, operator = sided(expr, operator)
          return unless column

          lower, upper = BOUNDS.fetch(operator)
          [column, lower && [lower, day], upper && [upper, day]]
        end

        # [the cast's ColumnRef, the other side, the operator as it reads
        # with the cast on its left], or nil.
        def sided(expr, operator)
          left = cast_column(expr.lexpr)
          return [left, expr.rexpr, operator] if left

          right = cast_column(expr.rexpr)
          [right, expr.lexpr, FLIPPED.fetch(operator)] if right
        end

        # The comparison's operator, if it's one of BOUNDS, bare or
        # pg_catalog's, or nil.
        def operator(expr)
          names = expr.name.map { it.string&.sval }
          names = names.drop(1) if names.size == 2 && names.first == "pg_catalog"
          names.first if names.size == 1 && BOUNDS.key?(names.first)
        end

        # The ColumnRef that node casts to date, or nil.
        def cast_column(node)
          arg = cast_arg(node)
          arg.column_ref if arg&.node == :column_ref
        end

        # What node casts to date, or nil. date isn't an aggregate, so a
        # call of it with DISTINCT, FILTER, OVER, or VARIADIC fails as it is.
        def cast_arg(node)
          case node.node
          when :type_cast then node.type_cast.arg if date?(node.type_cast.type_name)
          when :func_call then node.func_call.args.first if date_call?(node.func_call)
          end
        end

        def date_call?(call) = DATE.include?(call.funcname.map { it.string&.sval }) && call.args.size == 1

        # date takes no modifier, and a date array compares with no date, so
        # a cast the query can run that names date is a cast to date.
        def date?(type_name) = DATE.include?(type_name.names.map { it.string&.sval })

        # Whether column is a timestamp or timestamptz column of a plain
        # table in select's FROM.
        def column?(column, select, catalog)
          found = CountToExists::Counted.table_column(select.from_clause, column, catalog)
          TYPES.include?(catalog.column_info(*found)&.type) if found
        end

        # Whether node is a placeholder of a finite date whose next day is
        # still a timestamp.
        def day?(node, literals)
          cast = node.type_cast if node.node == :type_cast && date?(node.type_cast.type_name)
          param = node.param_ref || cast&.arg&.param_ref
          return false unless param

          day = "$#{param.number}::pg_catalog.date"
          literals.holds?(
            "pg_catalog.isfinite(#{day}) AND #{day}::pg_catalog.timestamp IS NOT NULL AND " \
            "#{day}::pg_catalog.timestamptz IS NOT NULL AND (#{day} OPERATOR(pg_catalog.+) 1)::pg_catalog.timestamp " \
            "IS NOT NULL AND (#{day} OPERATOR(pg_catalog.+) 1)::pg_catalog.timestamptz IS NOT NULL"
          )
        end
      end
    end
  end
end
