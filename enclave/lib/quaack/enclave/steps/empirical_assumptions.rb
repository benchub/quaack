# frozen_string_literal: true

require "pg_query"
require_relative "../rewrite_rules/tree"

module Quaack
  module Enclave
    module Steps
      # The denormalized_equal assumptions a stored rewrite rests on (DESIGN.md
      # assumption-check): what assumption-check found the data holds and the schema doesn't enforce, for
      # the report to name (DESIGN.md's report).
      #
      #   EmpiricalAssumptions.call(store.read("rewrite_1"))
      #   # => [{ "table" => "public.submissions", "column" => "course_id",
      #   #       "references_table" => "public.assignments",
      #   #       "type_column" => "context_type", "id_column" => "context_id" }]
      #
      # Trust boundary. These go out in the report message unchecked. Only
      # names already in the rewrite's own SQL, which the report sends, go
      # out: each table a table the SQL reads, and each column a column it
      # names. Anything else in the entry, the type value above all, which
      # is the query's literal, is never sent.
      module EmpiricalAssumptions
        TABLES = %w[table references_table].freeze
        COLUMNS = %w[column type_column id_column].freeze

        module_function

        def call(entry)
          names = names(entry["sql"])
          return [] unless names

          denormalized(entry).filter_map do |assumption|
            sent = assumption.slice(*TABLES, *COLUMNS)
            sent if named?(sent, TABLES, names[:tables]) && named?(sent, COLUMNS, names[:columns])
          end
        end

        def denormalized(entry)
          Array(entry["assumptions"]).select { it.is_a?(Hash) && it["kind"] == "denormalized_equal" }
        end

        def named?(sent, keys, names) = keys.all? { names.include?(sent[it]) }

        # Whether the entry rests on any denormalized_equal assumption, sent
        # or not.
        def any?(entry) = denormalized(entry).any?

        # The schema-qualified tables sql reads and the column names it
        # names, or nil if it doesn't parse.
        def names(sql)
          tree = PgQuery.parse(sql).tree
          tables = Enclave::RewriteRules::Tree.find(tree, PgQuery::RangeVar).map { "#{it.schemaname}.#{it.relname}" }
          columns = Enclave::RewriteRules::Tree.find(tree, PgQuery::ColumnRef).map { it.fields.last }
          columns = columns.select { it.node == :string }.map { it.string.sval }
          { tables:, columns: }
        rescue PgQuery::ParseError, TypeError
          nil
        end
      end
    end
  end
end
