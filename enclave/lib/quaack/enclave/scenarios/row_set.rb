# frozen_string_literal: true

require "pg"
require "pg_query"

module Quaack
  module Enclave
    module Scenarios
      # A scenario's rows, gathered a group at a time. A row already there
      # is kept once. A group with a row that would collide with an earlier
      # one on a primary key, unique constraint, or unique index is left out
      # whole. A key with a NULL collides with nothing, unless its index is
      # NULLS NOT DISTINCT. An expression unique index's keys are evaluated
      # in Postgres (conn) on the row's values, against a VALUES list; a row
      # whose keys can't be evaluated counts as colliding.
      class RowSet
        def initialize(schema, conn)
          @schema = schema
          @conn = conn
          @rows = Hash.new { |h, k| h[k] = [] }
          @evaluated = {}
        end

        # False when the group collides and is left out.
        def add?(group_rows)
          fresh = group_rows.reject { |r| @rows[r.table].include?(r) }
          return false if fresh.any? { |r| collides?(r) }

          fresh.each { |r| @rows[r.table] << r }
          true
        end

        def in_order(tables) = tables.flat_map { |t| @rows[t] }

        private

        def collides?(row)
          constraints = @schema.constraints(row.table)
          constraints.uniques.any? do |columns|
            clash?(row, constraints.nulls_not_distinct.include?(columns)) { |r| values(r, columns) }
          end || constraints.expressions.any? do |index|
            clash?(row, index.nulls_not_distinct) { |r| evaluate(r, index) }
          end
        end

        def clash?(row, nulls_collide)
          key = yield(row)
          return true if key == :error
          return false if key.any?(&:nil?) && !nulls_collide

          @rows[row.table].any? { |other| yield(other) == key }
        end

        def values(row, columns) = columns.map { |c| row.columns.index(c)&.then { |i| row.values[i] } }

        def evaluate(row, index)
          @evaluated.fetch([row, index]) { @evaluated[[row, index]] = run(row, index) }
        end

        # A column the row leaves out reads as NULL.
        def run(row, index)
          return :error unless index.keys.all? { |key| expression?(key) }

          select = index.keys.map { |key| "(#{key})::text" }.join(", ")
          @conn.exec_params("SELECT #{select}#{from(row.table, index.columns)}", values(row, index.columns)).values[0]
        rescue PG::Error
          :error
        end

        def from(table, columns)
          return "" if columns.empty?

          casts = columns.each_with_index.map { |c, i| "$#{i + 1}::#{@schema.column(table, c).type}" }
          " FROM (VALUES (#{casts.join(", ")})) AS t(#{columns.map { |c| @conn.quote_ident(c) }.join(", ")})"
        end

        # The catalog prints each key as one expression. Anything else isn't
        # run.
        def expression?(key)
          stmts = PgQuery.parse("SELECT #{key}").tree.stmts
          stmts.size == 1 && (select = stmts[0].stmt.select_stmt) && select.target_list.size == 1 &&
            select.from_clause.empty?
        rescue PgQuery::ParseError
          false
        end
      end
    end
  end
end
