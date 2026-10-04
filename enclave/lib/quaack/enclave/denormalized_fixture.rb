# frozen_string_literal: true

require_relative "arena_runner"
require_relative "rewrite_assumptions"
require_relative "table_name"

module Quaack
  module Enclave
    # Steps 9 and 10's fixtures for a rewrite from a 6c rule that rests on a
    # denormalized_equal assumption, which 6b checked against the data
    # (DESIGN.md 6c, 9, 10a). Such a rewrite is only right on data that
    # keeps the copy, so the arena makes its fixtures keep it too:
    #
    #   copies = DenormalizedFixture.copies(store.read("rewrite_1"))
    #   DenormalizedFixture::Runner.new(arena_connection, copies)   # an ArenaRunner
    #
    # copies reads only the entry's own assumptions, and only when a 6c
    # rule wrote it ("source" "rule"); 6b refuses the kind from anyone
    # else, and this is a second guard, so no other rewrite's fixtures are
    # bent to fit it.
    #
    # Runner's load runs inside ArenaRunner's transaction, after every row
    # and insert has loaded, so the arena rolls it back with the rest. With
    # no copies it's an ArenaRunner exactly. For each Copy it
    # drops the foreign keys on the copy column, since the copied id need
    # not be a row of the table the key names, and then sets the column to
    # the parent's id column on every row whose parent's type column is the
    # class, and no other row. Every name goes in as a quoted identifier
    # and the class as a parameter. A statement that fails is a load
    # failure (fixture_load_failed), never a disproof.
    module DenormalizedFixture
      Copy = Data.define(:table, :column, :join_column, :references_table, :references_column, :type_column,
                         :type_value, :id_column)

      KIND = "denormalized_equal"
      NAMES = %w[column join_column references_column type_column type_value id_column].freeze

      FOREIGN_KEYS = <<~SQL
        SELECT c.conname FROM pg_catalog.pg_constraint c
        WHERE c.conrelid = $1::regclass AND c.contype = 'f'
          AND EXISTS (SELECT 1 FROM pg_catalog.pg_attribute a
                      WHERE a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey) AND a.attname = $2)
      SQL

      module_function

      def copies(entry)
        return [] unless entry["source"] == "rule"

        entry.fetch("assumptions", []).select { it["kind"] == KIND }.map do |assumption|
          Copy.new(table: table(assumption["table"]), references_table: table(assumption["references_table"]),
                   **assumption.slice(*NAMES).transform_keys(&:to_sym))
        end
      end

      # An ArenaRunner whose every fixture keeps the copies.
      class Runner < ArenaRunner
        def initialize(connection, copies, **)
          raise ArgumentError, "copies must be an Array of Copies" unless copies.is_a?(Array) && copies.all?(Copy)

          super(connection, **)
          @copies = copies
        end

        private

        def load(...)
          super
          DenormalizedFixture.load(@copies, method(:statement), method(:quote))
        end
      end

      def table(name) = RewriteAssumptions.split(name).then { |schema, relname| TableName.new(schema:, name: relname) }

      # statement is the runner's; quote quotes an identifier.
      def load(copies, statement, quote)
        copies.each_with_index do |copy, index|
          run = ->(sql, params = []) { statement.call(sql, params, step: :load, rule: :fixture_load_failed, index:) }
          child = table_sql(copy.table, quote)
          run.call(FOREIGN_KEYS, [child, copy.column]).rows.each do |(name)|
            run.call("ALTER TABLE #{child} DROP CONSTRAINT #{quote.call(name)}")
          end
          run.call(update_sql(copy, child, quote), [copy.type_value])
        end
      end

      def update_sql(copy, child, quote)
        name = ->(key) { quote.call(copy.public_send(key)) }
        "UPDATE #{child} c SET #{name.call(:column)} = p.#{name.call(:id_column)} " \
          "FROM #{table_sql(copy.references_table, quote)} p " \
          "WHERE c.#{name.call(:join_column)} = p.#{name.call(:references_column)} " \
          "AND p.#{name.call(:type_column)} = $1 " \
          "AND c.#{name.call(:column)} IS DISTINCT FROM p.#{name.call(:id_column)}"
      end

      def table_sql(table, quote) = [table.schema, table.name].map { quote.call(it) }.join(".")
    end
  end
end
