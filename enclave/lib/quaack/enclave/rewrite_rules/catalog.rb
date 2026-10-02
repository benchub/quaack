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
      # It also gives a table's column names, in the table's order, which
      # is what a star in a select list stands for:
      #
      #   catalog.columns("public", "orders")   # => ["id", "customer_id", "total"]
      #
      # A table that doesn't exist has none. They're read once per table.
      class Catalog
        COLUMNS = <<~SQL
          SELECT a.attname FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
          ORDER BY a.attnum
        SQL

        def initialize(connection)
          @connection = connection
          @met = {}
          @columns = {}
        end

        def columns(schema, table)
          @columns[[schema, table]] ||= @connection.exec_params(COLUMNS, [schema, table]).column_values(0)
        end

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
