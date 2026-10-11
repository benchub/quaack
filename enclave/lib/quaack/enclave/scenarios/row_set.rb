# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "../deadline"
require_relative "held"

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
        # The rows, in an insertion-ordered Hash per table, and each key a
        # check looks up (a unique key, an expression index's keys, a foreign
        # key's parent columns) in a Hash from key to the rows that hold it,
        # built the first time it's needed, so a check costs the same however
        # many rows there are (task 20261011-4). key computes a row's key of
        # a kind (a column list or an expression index).
        class Table
          def initialize(&key)
            @key = key
            @rows = Hash.new { |h, k| h[k] = {} }
            @indexes = Hash.new { |h, k| h[k] = {} }
          end

          def include?(row) = @rows[row.table].key?(row)

          def rows(table) = @rows[table].keys

          def insert(row)
            @rows[row.table][row] = true
            @indexes[row.table].each { |kind, index| (index[@key.call(row, kind)] ||= {})[row] = true }
          end

          def remove(row)
            @rows[row.table].delete(row)
            @indexes[row.table].each do |kind, index|
              found = @key.call(row, kind)
              index[found].delete(row)
              index.delete(found) if index[found].empty?
            end
          end

          # The rows of table whose key of kind is wanted, in the order they
          # came, or nil when there are none.
          def holding(table, kind, wanted)
            index = @indexes[table].fetch(kind) do
              @indexes[table][kind] = {}.tap do |built|
                @rows[table].each_key { |r| (built[@key.call(r, kind)] ||= {})[r] = true }
              end
            end
            index[wanted]
          end
        end

        # held keeps each group's Held by the group's Array, so RowSets that
        # share it, as a Parts' do, gather a group's keys once (task
        # 20261011-13). A group's Array never changes.
        def initialize(schema, conn, evaluated = {}, held = {}.compare_by_identity)
          @held = held
          @schema = schema
          @conn = conn
          @rows = Table.new { |row, kind| kind.is_a?(Array) ? values(row, kind) : evaluate(row, kind) }
          @evaluated = evaluated
        end

        # False when the group collides or lacks a parent, and is left out.
        # Its rows are checked one at a time, each against the ones before.
        def add?(group_rows)
          Deadline.check!
          fresh = group_rows.reject { |r| @rows.include?(r) }.uniq
          held = held(group_rows)
          fresh.each_with_index do |r, i|
            next @rows.insert(r) unless collides?(r) || orphan?(r, held)

            fresh.first(i).each { @rows.remove(it) }
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
        # less rows themselves. A foreign key that a row of rows already
        # matches is the group's own, so the row here of that key isn't
        # lifted: a near miss pinned to the hit's parent key brings its own
        # parent of that key, and both can't share a fixture.
        def parents_of(rows)
          found = {}
          own = rows.to_h { [it, true] }
          queue = rows.dup
          while (row = queue.shift)
            outside_parents(row, held ||= held(rows)).each do |parent|
              next if found.key?(parent) || own.key?(parent)

              queue << found.store(parent, parent)
            end
          end
          found.keys
        end

        # The rows, table by table.
        def in_order(tables) = tables.flat_map { @rows.rows(it) }

        private

        def held(rows) = @held[rows] ||= Held.new(rows) { |r, columns| values(r, columns) }

        def outside_parents(row, held)
          @schema.constraints(row.table).foreign_keys.filter_map do |key|
            wanted = values(row, key.columns)
            next if held.held?(key.parent, key.parent_columns, wanted)

            parent(row, key)
          end
        end

        def parent(row, key)
          wanted = values(row, key.columns)
          @rows.holding(key.parent, key.parent_columns, wanted)&.first&.first unless wanted.any?(&:nil?)
        end

        # A foreign key with a NULL column checks nothing (MATCH SIMPLE).
        def orphan?(row, held)
          @schema.constraints(row.table).foreign_keys.any? do |fk|
            key = values(row, fk.columns)
            key.none?(&:nil?) && parent(row, fk).nil? &&
              !held.held?(fk.parent, fk.parent_columns, key)
          end
        end

        def collides?(row)
          constraints = @schema.constraints(row.table)
          constraints.uniques.any? do |columns|
            clash?(row, columns, constraints.nulls_not_distinct.include?(columns))
          end || constraints.expressions.any? do |index|
            clash?(row, index, index.nulls_not_distinct)
          end
        end

        def clash?(row, kind, nulls_collide)
          wanted = kind.is_a?(Array) ? values(row, kind) : evaluate(row, kind)
          return true if wanted == :error
          return false if wanted.any?(&:nil?) && !nulls_collide

          !@rows.holding(row.table, kind, wanted).nil?
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

          select = index.keys.map { |key| "(#{key})::pg_catalog.text" }.join(", ")
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
