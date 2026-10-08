# frozen_string_literal: true

require "pg_query"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Scenarios
      # The fixture tables' CHECK constraints, as conditions on one column
      # each. A CHECK is simple when it's an AND of tests of one column
      # (or a cast of it) against expressions with no column: a comparison,
      # = ANY (ARRAY[...]) (how Postgres prints IN), an IN list, BETWEEN,
      # or IS [NOT] NULL. Anything else, such as lo < hi, an OR, or a
      # function of the column, raises Error(:complex_check), so the query
      # is refused. Postgres evaluates each condition, as for the pools.
      class Checks
        OPERATORS = %w[= <> < <= > >=].freeze
        KINDS = %i[AEXPR_OP AEXPR_OP_ANY AEXPR_IN AEXPR_BETWEEN AEXPR_NOT_BETWEEN].freeze

        def initialize(conn, schema)
          @conn = conn
          @schema = schema
          @nodes = Hash.new { |h, k| h[k] = [] }
          schema.tables.each do |table|
            schema.constraints(table).checks.each { |definition| add(table, definition) }
          end
          @probes = {}
          @own_values = {}
          @shared = {}
          @sorted = {}
        end

        # Whether value passes every CHECK on the column. NULL passes a
        # test that comes out NULL, as in Postgres.
        def allows?(table, col, value)
          probes(table, col).none? { |p| ["f", :unreadable].include?(p.call(value)) }
        end

        # The first of preferred, then each CHECK's own satisfying values,
        # that passes every CHECK on the column. With none, it raises
        # refusal, if given, or unsatisfiable_check. The CHECKs' own values
        # are sorted only when no preferred value passes.
        def satisfying(table, col, preferred, refusal = nil)
          found = ->(values) { values.compact.find { |v| allows?(table, col, v) } }
          found.call(preferred) || found.call(own_values(table, col)) ||
            raise(refusal || Error.new(:unsatisfiable_check))
        end

        # Each CHECK's own satisfying values for the column. One may still
        # break another CHECK on it.
        def values(table, col) = own_values(table, col)

        # Whether any CHECK constrains the column.
        def checked?(table, col) = @nodes[[table, col.name]].any?

        private

        # A CHECK's answer for a value never changes, so each probe asks
        # Postgres once per value. Columns of one type with the same CHECK,
        # such as many tables' workflow_state, share a probe.
        def probes(table, col)
          @probes[[table, col.name]] ||= @nodes[[table, col.name]].map do |n|
            probe = ValuePools::Probe.new(@conn, n, col)
            @shared[probe.key] ||= ValuePools::CachedProbe.new(probe)
          end
        end

        def own_values(table, col)
          @own_values[[table, col.name]] ||= @nodes[[table, col.name]].zip(probes(table, col)).flat_map do |n, p|
            @sorted[[p, col.nullable]] ||= ValuePools.sorted(@conn, n, col, p)[:satisfying]
          end
        end

        def add(table, definition)
          where = PgQuery.parse("SELECT 1 WHERE #{definition.delete_prefix("CHECK ")}").tree
                         .stmts[0].stmt.select_stmt.where_clause
          conjuncts(where).each do |node|
            name = column_of(node)
            raise Error, :complex_check unless name && @schema.column(table, name)

            @nodes[[table, name]] << node
          end
        rescue PgQuery::ParseError, KeyError
          raise Error, :complex_check
        end

        def conjuncts(node)
          b = node.bool_expr
          b && b.boolop == :AND_EXPR ? b.args.flat_map { |a| conjuncts(a) } : [node]
        end

        def column_of(node)
          return column_name(node.null_test.arg) if node.null_test
          return nil unless simple_test?(node.a_expr)

          single_column([node.a_expr.lexpr, node.a_expr.rexpr])
        end

        # The column one side names, when the other side names none.
        def single_column(sides)
          names = sides.map { |s| column_name(s) }
          return nil unless names.compact.size == 1

          other = sides[names.index(nil)]
          names.compact.first if other && !ValuePools::Sides.column_ref?(other)
        end

        def simple_test?(expr)
          return false unless expr && KINDS.include?(expr.kind)

          expr.kind != :AEXPR_OP || operator?(expr.name.map { it.string.sval })
        end

        # pg_get_constraintdef puts pg_catalog on an operator that the
        # search_path finds another of first, such as one a dump plants in
        # public.
        def operator?(name) = OPERATORS.include?(name.last) && [[name.last], ["pg_catalog", name.last]].include?(name)

        def column_name(node)
          return nil unless node

          node = node.type_cast.arg if node.type_cast
          node.column_ref && node.column_ref.fields.last&.string&.sval
        end
      end
    end
  end
end
