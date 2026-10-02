# frozen_string_literal: true

require_relative "../assumption_check"
require_relative "../rewrite_assumptions"

module Quaack
  module Enclave
    module RewriteRules
      # The catalog facts a rule may rely on (DESIGN.md 6c). A rule states
      # each fact as an assumption in 6b's vocabulary (see
      # RewriteAssumptions) and asks whether the catalog proves it:
      #
      #   catalog = Catalog.new(connection)
      #   catalog.met?("kind" => "not_null", "table" => "public.orders", "column" => "id")   # => true
      #
      # That's 6b's own AssumptionCheck, so a rule fires on exactly the
      # facts 6b will accept when it checks the rewrite again. An
      # assumption the vocabulary can't state, such as one on a table whose
      # name has a space, is never met. Each answer is kept for the life of
      # the Catalog. connection is read only, as AssumptionCheck reads it.
      #
      # It also lists a table's columns, in the table's order, for a rule
      # that writes a UNION, and just their names, which is what a star in a
      # select list stands for:
      #
      #   catalog.columns("public", "orders")        # => [Column(name: "id", comparable: true), ...]
      #   catalog.column_names("public", "orders")   # => ["id", "customer_id", "total"]
      #
      # comparable says UNION can tell two of the column's values apart as
      # the column's own equality does: its type is an enum or one of
      # COMPARABLE, the built-in types known to hash and sort, and its
      # collation, if it has one, is deterministic. That isn't one of 6b's
      # facts, and no rewrite's rows depend on it: a UNION over a type with
      # no equality, such as json, is an error, not other rows. A table
      # that doesn't exist has no columns.
      class Catalog
        Column = Data.define(:name, :comparable)

        COMPARABLE = %w[bool int2 int4 int8 oid float4 float8 numeric text varchar bpchar name uuid date time timetz
                        timestamp timestamptz interval bytea].freeze

        # A dropped column has no type, so the join to pg_type leaves it out.
        COLUMNS = <<~SQL.freeze
          SELECT a.attname,
                 (t.typtype = 'e' OR (n.nspname = 'pg_catalog' AND t.typname = ANY ($3::text[])))
                 AND (a.attcollation = 0 OR co.collisdeterministic)
          FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
          JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
          LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
          WHERE a.attrelid = #{AssumptionCheck::RELATION} AND a.attnum > 0
          ORDER BY a.attnum
        SQL

        def initialize(connection)
          @connection = connection
          @met = {}
          @columns = {}
        end

        def columns(schema, table)
          @columns[[schema, table]] ||=
            @connection.exec_params(COLUMNS, [schema, table, "{#{COMPARABLE.join(",")}}"]).values
                       .map { |name, comparable| Column.new(name:, comparable: comparable == "t") }
        end

        def column_names(schema, table) = columns(schema, table).map(&:name)

        def met?(assumption)
          @met.fetch(assumption) do
            @met[assumption] = RewriteAssumptions.assumption?(assumption) &&
                               AssumptionCheck.met?(assumption, @connection)
          end
        end
      end
    end
  end
end
