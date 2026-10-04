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
      # column, NULL for a nullable foreign key, its own key for a NOT NULL
      # one to its own table, a new parent row for another NOT NULL one,
      # and a type-typical or CHECK-satisfying value otherwise. A nullable
      # column of a type with no such value is left NULL when Nulls allows
      # it, given reads (Scenarios::Reads over the queries the fixture
      # runs); with no reads, it's refused.
      class ParentRows
        # Distinct values start here, clear of the small numbers the LLM
        # tends to use for keys.
        FIRST = 9_000

        attr_reader :rows

        def initialize(conn, schema, accepted, reads = nil)
          @conn = conn
          @schema = schema
          @values = Scenarios::Values.new(conn)
          @checks = Scenarios::Checks.new(conn, schema)
          @nulls = Scenarios::Nulls.new(schema, @values, @checks, reads) if reads
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
          varying = varying(table, pairs)
          free = @schema.columns(table).reject { |col| pairs.key?(col.name) || omitted?(varying, col) }
          add(table, pairs.merge(free.to_h { |col| [col.name, free_value(table, col, varying)] }))
        end

        def present?(table, fixed) = @present[table].any? { |row| fixed.all? { |c, v| row[c] == v } }

        def add(table, pairs)
          @present[table] << pairs
          @rows << ArenaRunner::FixtureRow.new(table:, columns: pairs.keys, values: pairs.values)
        end

        # Values for the row's foreign keys that fixed doesn't set, and for
        # the columns of its own table a self-reference points at.
        def foreign_keys(table, fixed)
          @schema.constraints(table).foreign_keys.each_with_object({}) do |fk, pairs|
            next if fk.columns.any? { |c| fixed.key?(c) }

            pairs.merge!(foreign_key(table, fk, fixed.merge(pairs)))
          end
        end

        # NULLs when a column is nullable, the row's own key for a NOT NULL
        # foreign key to its own table, or else a new parent row's key.
        def foreign_key(table, foreign, fixed)
          return foreign.columns.to_h { [it, nil] } if foreign.columns.any? { |c| @schema.column(table, c).nullable }
          return own_key(foreign, fixed) if foreign.parent == table

          new_parent(foreign)
        end

        # A new parent row, and the foreign key's values that point at it.
        def new_parent(foreign)
          key = parent_key(foreign)
          need(foreign.parent, foreign.parent_columns.zip(key).to_h)
          foreign.columns.zip(key).to_h
        end

        # The row's own values of the columns a foreign key to its own table
        # references, with a distinct value for each one the row doesn't set.
        def own_key(foreign, fixed)
          key = foreign.parent_columns.map { |c| fixed[c] || distinct(foreign, c) }
          foreign.parent_columns.zip(key).to_h.merge(foreign.columns.zip(key).to_h)
        end

        # A new parent row's key, a distinct value in each column.
        def parent_key(foreign) = foreign.parent_columns.map { distinct(foreign, it) }

        def distinct(foreign, column)
          @values.nth(@schema.column(foreign.parent, column), @counter += 1, table: foreign.parent)
        end

        # A unique column with a default still needs a distinct value, but a
        # generated one can't take any.
        def omitted?(varying, col)
          col.default == "generated" || (!col.default.nil? && !col.default.empty? && !unique?(varying, col))
        end

        def unique?(varying, col) = varying.include?(col.name)

        # The columns pairs doesn't set that need a distinct value per row.
        def varying(table, pairs)
          free = @schema.columns(table).reject { |col| pairs.key?(col.name) || col.default == "generated" }
          @schema.constraints(table).varying(free) { [@values.rank(it), @checks.checked?(table, it) ? 1 : 0] }
        end

        def free_value(table, col, varying)
          return @values.nth(col, @counter += 1, table:) if unique?(varying, col)

          typical = @values.typical(col)
          @checks.satisfying(table, col, [typical], (@values.refusal(col, table) unless typical))
        rescue Scenarios::Error
          raise if typical || !null?(table, col)

          nil
        end

        def null?(table, col) = @nulls&.allowed?(table, col)
      end
    end
  end
end
