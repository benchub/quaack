# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"

module Quaack
  module Enclave
    module RewriteRules
      class ImpliedPredicateRemoval
        # Finds the conjuncts that repeat an earlier one exactly, with the
        # same literals, so dropping them changes nothing. A copy that reads
        # a column with a nondeterministic collation, or might call a
        # volatile function, is kept.
        module Duplicates
          def duplicates(terms, catalog, literals, select)
            terms.each_with_index.with_object([]) do |(term, i), drop|
              first = terms[0...i].find do |other|
                same_expression?(other.condition, term.condition, literals) &&
                  deterministic_columns?(term.condition, catalog, select) && !volatile?(term.condition, catalog)
              end
              drop << i if first
            end
          end

          # A volatile call gives each copy its own value, as random() does.
          def volatile?(condition, catalog)
            filter = PgQuery.parse("SELECT WHERE true").tree.stmts.first.stmt.select_stmt
            filter.where_clause = Deparse.copy(condition)
            catalog.calls_volatile?(Deparse.statement(filter))
          rescue Deparse::Error
            true
          end

          def deterministic_columns?(condition, catalog, select)
            columns(condition).all? do |column|
              info = column_info(column, select, catalog)
              info&.deterministic
            end
          end
        end
      end
    end
  end
end
