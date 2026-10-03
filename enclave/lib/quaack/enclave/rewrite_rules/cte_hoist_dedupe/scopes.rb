# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module RewriteRules
      class CteHoistDedupe
        # Every CTE in a SELECT, and the CTE each unqualified table name
        # reads, by Postgres's scoping: a WITH's CTEs are seen by the rest
        # of its statement, subqueries included, and each by the CTEs after
        # it in the list, or by all of them under RECURSIVE. A nearer one
        # hides a farther one of the same name.
        #
        # An Entry's cte is its CommonTableExpr, with_clause the WithClause
        # holding it, and owner the statement that WithClause belongs to. inside lists the
        # CTEs whose bodies hold it, outermost first. A Ref's target is the
        # CommonTableExpr its RangeVar reads, or nil for a table.
        class Scopes
          Entry = Data.define(:cte, :with_clause, :owner, :inside)
          Ref = Data.define(:range_var, :target, :inside)

          attr_reader :ctes, :refs

          def initialize(select)
            @ctes = []
            @refs = []
            @entries = {}.compare_by_identity
            walk(select, {}, [])
          end

          def entry(cte) = @entries[cte]

          # Whether node, an Entry or a Ref, is in cte's body.
          def within?(node, cte) = node.inside.any? { it.equal?(cte) }

          private

          def walk(node, scope, inside)
            case node
            when Google::Protobuf::RepeatedField then node.each { walk(it, scope, inside) }
            when PgQuery::SelectStmt then select(node, scope, inside)
            when PgQuery::RangeVar then range_var(node, scope, inside)
            when Google::Protobuf::MessageExts then fields(node, scope, inside)
            end
          end

          def fields(node, scope, inside, skip = nil)
            node.class.descriptor.each { walk(it.get(node), scope, inside) unless it.name == skip }
          end

          def select(stmt, scope, inside)
            scope = with(stmt.with_clause, stmt, scope, inside) if stmt.with_clause
            fields(stmt, scope, inside, "with_clause")
          end

          # The scope the rest of owner sees, after walking each CTE's body.
          def with(with, owner, scope, inside)
            ctes = with.ctes.map(&:common_table_expr)
            ctes.each_with_index do |cte, i|
              @entries[cte] = Entry.new(cte:, with_clause: with, owner:, inside:).tap { @ctes << it }
              walk(cte.ctequery, named(scope, with.recursive ? ctes : ctes.first(i)), inside + [cte])
            end
            named(scope, ctes)
          end

          def named(scope, ctes) = scope.merge(ctes.to_h { [it.ctename, it] })

          def range_var(node, scope, inside)
            @refs << Ref.new(range_var: node, target: scope[node.relname], inside:) if node.schemaname.empty?
          end
        end
      end
    end
  end
end
