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
      # whose keys can't be evaluated counts as colliding. So is a group
      # with a row whose foreign key points at a parent row neither here nor
      # in the group (one a left-out group held).
      #
      # evaluated holds each expression index's keys for the values of its
      # columns, so RowSets that share it, as a build's do, ask Postgres
      # once per distinct value.
      class RowSet
        def initialize(schema, conn, evaluated = {})
          @schema = schema
          @conn = conn
          @rows = Hash.new { |h, k| h[k] = [] }
          @evaluated = evaluated
        end

        # False when the group collides or lacks a parent, and is left out.
        # Its rows are checked one at a time, each against the ones before.
        def add?(group_rows)
          fresh = group_rows.reject { |r| @rows[r.table].include?(r) }.uniq
          fresh.each_with_index do |r, i|
            next @rows[r.table] << r unless collides?(r) || orphan?(r, group_rows)

            fresh.first(i).each { @rows[it.table].delete(it) }
            return false
          end
          true
        end

        # Adds the first of tries (a group's rows, then the same group with
        # other values, or nil when it can't be built) that doesn't
        # collide, stopping at a nil or a repeat. False when none does.
        def add_any?(tries)
          tried = []
          tries.each do |rows|
            break if rows.nil? || tried.include?(rows)
            return true if add?(rows)

            tried << rows
          end
          false
        end

        # The rows here that rows point at by foreign key, and theirs, on up,
        # less rows themselves.
        def parents_of(rows)
          found = []
          queue = rows.dup
          while (row = queue.shift)
            parents(row).each do |parent|
              next if found.include?(parent) || rows.include?(parent)

              found << parent
              queue << parent
            end
          end
          found
        end

        # The rows, table by table.
        def in_order(tables) = tables.flat_map { |t| @rows[t] }

        private

        def parents(row) = @schema.constraints(row.table).foreign_keys.filter_map { parent(row, it) }

        def parent(row, key)
          wanted = values(row, key.columns)
          @rows[key.parent].find { values(it, key.parent_columns) == wanted } unless wanted.any?(&:nil?)
        end

        # A foreign key with a NULL column checks nothing (MATCH SIMPLE).
        def orphan?(row, group_rows)
          @schema.constraints(row.table).foreign_keys.any? do |fk|
            key = values(row, fk.columns)
            key.none?(&:nil?) && parent(row, fk).nil? &&
              group_rows.none? { |r| r.table == fk.parent && values(r, fk.parent_columns) == key }
          end
        end

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

        # The keys depend only on the table, the index, and the values of
        # its columns (see run).
        def evaluate(row, index)
          key = [row.table, index, values(row, index.columns)]
          @evaluated.fetch(key) { @evaluated[key] = run(row, index) }
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
