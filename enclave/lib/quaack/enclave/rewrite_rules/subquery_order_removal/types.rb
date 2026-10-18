# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class SubqueryOrderRemoval
        # Whether the values of an order-blind reader whose type matters
        # have types that keep it blind (see Blind).
        #
        # min and max keep the first of two values that compare equal, and
        # so do a GROUP BY, for each of its items, and a plain DISTINCT, for
        # each column it keeps. So each of those values must be of a type
        # whose equal values look the same (Types.same_type?). A sum or avg
        # of a float rounds in its input's order, and one of an interval or
        # money can overflow in one order and not another, so what they add
        # must be an integer or a numeric (EXACT).
        #
        # Those types come from Postgres, which can type the reader's
        # values only when the reader is the top-level SELECT. A reader that
        # needs a type anywhere else, or of an aggregate under a subquery,
        # isn't blind. Catalog#result_types types them with each
        # placeholder left for Postgres to type, as an untyped string is,
        # but a placeholder for 1.5 is a numeric, and one for 1 an integer,
        # which can give a value another type. So the literal oracle then
        # prepares the same values, each placeholder declared its literal's
        # own type, each as pg_catalog.btarraycmp(ARRAY[value],
        # ARRAY[NULL::type]), which takes two arrays of exactly one type. If
        # that doesn't prepare, the reader isn't blind. Literals keeps a
        # placeholder that isn't compared with a column at its slow literal
        # in every set, and a compared one sits in a condition, so a value's
        # type is the same in every set the rewrite runs with. A placeholder
        # whose type Postgres reads otherwise when it's untyped, such as
        # each of VALUES (1), (2), makes the reader refused. So does a
        # domain's value, which Postgres describes as its base type, and a
        # star, such as the d.* of SELECT DISTINCT d.*, since ARRAY[d.*] is
        # an array of rows.
        module Types
          EXACT = %w[smallint integer bigint numeric].freeze

          # Types whose = holds only for the same value, which looks the
          # same.
          SAME = ["smallint", "integer", "bigint", "oid", "boolean", "date", "time without time zone",
                  "timestamp without time zone", "timestamp with time zone", "uuid", "bytea"].freeze

          # Types whose = holds only for the same value under a
          # deterministic collation.
          TEXT = ["text", "character varying", "name"].freeze

          # Asserts that the value in the first ARRAY has the type.
          ASSERT = "SELECT WHERE pg_catalog.btarraycmp(ARRAY[NULL], ARRAY[NULL::%s])"

          module_function

          # Whether the values that calls, Blind::Calls of the reader
          # select, and its GROUP BY and DISTINCT read have types that keep
          # it blind.
          def fit?(select, calls, tree, catalog, literals)
            exact = arguments(calls, :exact)
            values = exact + arguments(calls, :same) + keys(select)
            return true if values.empty?
            return false unless literals && select.equal?(Tree.select(tree)) && values.all?

            types = probe(select, values)&.then { catalog.result_types(it) }
            allowed?(types, exact.size, tree, catalog) && confirmed?(select, values, types, literals)
          end

          def arguments(calls, kind) = calls.select { it.kind == kind }.map { it.call.args.first }

          # The GROUP BY's items, each select-list item a number stands for
          # in its place (nil if there's none), and the select list's items
          # if it's DISTINCT.
          def keys(select)
            group = select.group_clause.map { grouped(it, select) }
            group + (select.distinct_clause.any? ? select.target_list.map { it.res_target.val } : [])
          end

          def grouped(item, select)
            return item unless item.node == :a_const && item.a_const.val == :ival

            number = item.a_const.ival.ival
            select.target_list[number - 1]&.res_target&.val if number.positive?
          end

          # Whether the first exact of types are EXACT and the rest
          # same_type?.
          def allowed?(types, exact, tree, catalog)
            !types.nil? && types.first(exact).all? { EXACT.include?(it) } &&
              types.drop(exact).all? { same_type?(it, tree, catalog) }
          end

          # Whether the literal oracle prepares each value as its type.
          def confirmed?(select, values, types, literals)
            sql = probe(select, values.zip(types).map { |value, type| asserted(value, type) })
            !sql.nil? && literals.prepares?(sql)
          end

          # btarraycmp(ARRAY[value], ARRAY[NULL::type]), for a type of
          # EXACT, SAME, or TEXT.
          def asserted(value, type)
            call = Tree.where_of(format(ASSERT, type))
            call.func_call.args.first.a_array_expr.elements[0] = Deparse.copy(value)
            call
          end

          # The SQL of the reader with values as its select list, and no
          # GROUP BY, HAVING, DISTINCT, ORDER BY, LIMIT, or OFFSET, which
          # Postgres types as the reader would type them. nil if it doesn't
          # deparse.
          def probe(select, values)
            probe = Deparse.copy(select)
            probe.target_list.replace(values.map { PgQuery::Node.from(PgQuery::ResTarget.new(val: Deparse.copy(it))) })
            [probe.group_clause, probe.distinct_clause, probe.sort_clause].each(&:clear)
            probe.having_clause = probe.limit_count = probe.limit_offset = nil
            probe.limit_option = :LIMIT_OPTION_DEFAULT
            Deparse.statement(probe)
          rescue Deparse::Error
            nil
          end

          # Whether type's equal values look the same. Text's do when no
          # column, domain, or range uses a nondeterministic collation and
          # the statement names no collation, so every collation it uses
          # is deterministic.
          def same_type?(type, tree, catalog)
            SAME.include?(type) || (TEXT.include?(type) && !catalog.nondeterministic_collations? &&
                                    Tree.find(tree, PgQuery::CollateClause).empty?)
          end
        end
      end
    end
  end
end
