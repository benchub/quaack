# frozen_string_literal: true

require "pg"
require_relative "../arena_fixture"
require_relative "../scenarios"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Counterexamples
      # The parent rows that fill the accepted inserts' foreign-key gaps.
      # A foreign-key value is read by evaluating the insert's value in
      # arena (it passed the inbound check, so it's immutable). A value
      # that's NULL or DEFAULT, or a column the insert leaves out, needs no
      # parent. A parent row takes the referenced values, and the step 9
      # rules for everything else: a DEFAULT, a distinct value for a unique
      # column, NULL for a nullable foreign key, a new parent row for a NOT
      # NULL one, and a type-typical or CHECK-satisfying value otherwise.
      class ParentRows
        # Distinct values start here, clear of the small numbers the LLM
        # tends to use for keys.
        FIRST = 9_000

        attr_reader :rows

        def initialize(conn, schema, accepted)
          @conn = conn
          @schema = schema
          @values = Scenarios::Values.new(conn)
          @checks = Scenarios::Checks.new(conn, schema)
          @counter = FIRST
          @rows = []
          fill_all(accepted.map { |a| [a.table, evaluate(a.parse)] })
        end

        private

        def fill_all(evaluated)
          @present = Hash.new { |h, k| h[k] = [] }
          evaluated.each { |table, rows| @present[table].concat(rows) }
          # Only once every insert's rows are present, so none gets a
          # parent another insert supplies.
          evaluated.each { |table, rows| rows.each { |row| fill(table, row) } } # rubocop:disable Style/CombinableLoops
        end

        # Each VALUES row as { column => text }, with :default for DEFAULT.
        def evaluate(parse)
          stmt = parse.tree.stmts[0].stmt.insert_stmt
          columns = stmt.cols.map { |c| c.res_target.name }
          stmt.select_stmt.select_stmt.values_lists.map { |list| columns.zip(texts(list)).to_h }
        end

        def texts(list) = list.list.items.map { |value| text(value) }

        def text(value)
          return :default if value.set_to_default

          @conn.exec("SELECT (#{ValuePools::Sides.select_of(value).delete_prefix("SELECT ")})::text").getvalue(0, 0)
        end

        def fill(table, row)
          @schema.constraints(table).foreign_keys.each do |fk|
            key = fk.columns.map { |c| row[c] }
            next if key.any? { |v| v.nil? || v == :default }

            need(fk.parent, fk.parent_columns.zip(key).to_h)
          end
        end

        def need(table, fixed)
          return if present?(table, fixed)

          pairs = fixed.merge(foreign_keys(table, fixed))
          free = @schema.columns(table).reject { |col| pairs.key?(col.name) || omitted?(table, col) }
          add(table, pairs.merge(free.to_h { |col| [col.name, free_value(table, col)] }))
        end

        def present?(table, fixed) = @present[table].any? { |row| fixed.all? { |c, v| row[c] == v } }

        def add(table, pairs)
          @present[table] << pairs
          @rows << ArenaRunner::FixtureRow.new(table:, columns: pairs.keys, values: pairs.values)
        end

        # Values for the row's foreign keys that fixed doesn't set.
        def foreign_keys(table, fixed)
          @schema.constraints(table).foreign_keys.each_with_object({}) do |fk, pairs|
            next if fk.columns.any? { |c| fixed.key?(c) } || fk.parent == table

            pairs.merge!(fk.columns.zip(foreign_key(table, fk)).to_h)
          end
        end

        # NULLs when a column is nullable, or else a new parent row's key.
        def foreign_key(table, foreign)
          return foreign.columns.map { nil } if foreign.columns.any? { |c| @schema.column(table, c).nullable }

          key = foreign.parent_columns.map { |c| @values.nth(@schema.column(foreign.parent, c), @counter += 1) }
          need(foreign.parent, foreign.parent_columns.zip(key).to_h)
          key
        end

        # A unique column with a default still needs a distinct value, but a
        # generated one can't take any.
        def omitted?(table, col)
          col.default == "generated" || (!col.default.nil? && !col.default.empty? && !unique?(table, col))
        end

        def unique?(table, col) = @schema.constraints(table).uniques.any? { |u| u.include?(col.name) }

        def free_value(table, col)
          return @values.nth(col, @counter += 1) if unique?(table, col)

          @checks.satisfying(table, col, [@values.typical(col, strict: false)])
        end
      end
    end
  end
end
