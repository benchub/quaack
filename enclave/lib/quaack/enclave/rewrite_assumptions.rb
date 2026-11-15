# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The structured assumptions a rewrite states (DESIGN.md's llm-rewrites), and their
    # vocabulary, which is exactly these five kinds:
    #
    #   { "kind" => "not_null", "table" => "public.orders", "column" => "id" }
    #   { "kind" => "unique", "table" => "public.orders", "columns" => ["id"] }
    #   { "kind" => "foreign_key", "table" => "public.orders", "columns" => ["customer_id"],
    #     "references_table" => "public.customers", "references_columns" => ["id"] }
    #   { "kind" => "check", "table" => "public.orders", "expression" => "total >= 0" }
    #   { "kind" => "denormalized_equal", "table" => "public.submissions", "column" => "course_id",
    #     "join_column" => "assignment_id", "references_table" => "public.assignments",
    #     "references_column" => "id", "type_column" => "context_type", "type_value" => "Course",
    #     "id_column" => "context_id" }
    #
    # denormalized_equal is rewrite-rules' polymorphic_key_copy's: every table row
    # joined to a references_table row on join_column = references_column,
    # where that row's type_column is type_value, has column equal to its
    # id_column. Only the data can say so, so assumption-check checks it there.
    #
    # A table is always "schema.name". An assumption that isn't exactly one
    # of these, with nothing missing or extra, makes RewriteAssumptions.valid?
    # false, and the rewrite is rejected as bad_assumption.
    module RewriteAssumptions
      KINDS = {
        "not_null" => { "table" => :name, "column" => :string },
        "unique" => { "table" => :name, "columns" => :strings },
        "foreign_key" => { "table" => :name, "columns" => :strings, "references_table" => :name,
                           "references_columns" => :strings },
        "check" => { "table" => :name, "expression" => :string },
        "denormalized_equal" => { "table" => :name, "column" => :string, "join_column" => :string,
                                  "references_table" => :name, "references_column" => :string,
                                  "type_column" => :string, "type_value" => :string, "id_column" => :string }
      }.freeze

      TABLE_NAME = /\A[^.\s]+\.[^.\s]+\z/

      module_function

      def valid?(assumptions)
        assumptions.is_a?(Array) && assumptions.all? { assumption?(it) }
      end

      def assumption?(assumption)
        return false unless assumption.is_a?(Hash)

        fields = KINDS[assumption["kind"]]
        return false unless fields && assumption.keys.sort == (["kind"] + fields.keys).sort

        fields.all? { |key, form| form?(assumption[key], form) }
      end

      def form?(value, form)
        case form
        when :name then string?(value) && TABLE_NAME.match?(value)
        when :string then string?(value)
        when :strings then value.is_a?(Array) && !value.empty? && value.all? { string?(it) }
        end
      end

      def string?(value) = value.is_a?(String) && !value.empty?

      # The form rewrite dedupe compares (DESIGN.md's rewrite-rules): a
      # check's expression in normal_expression form, each other string
      # value stripped with inner whitespace collapsed to one space, its
      # keys sorted, and the assumptions sorted, so the
      # same ones in another order or spacing compare equal. A column list
      # keeps its order, which a foreign key pairs on. It's only ever a
      # lookup key, never stored or sent, and it holds nothing the raw
      # assumptions didn't.
      def normalized(assumptions)
        Array(assumptions).map { normal_value(it) }.sort_by(&:inspect)
      end

      def normal_value(value, key = nil)
        case value
        when String then key == "expression" ? normal_expression(value) : value.strip.gsub(/\s+/, " ")
        when Array then value.map { normal_value(it) }
        when Hash then value.sort.to_h { |key, inner| [key, normal_value(inner, key)] }
        else value
        end
      end

      # A check expression as pg_query deparses it, so spacing outside
      # quoted text doesn't matter and spacing inside it does. Two compare
      # equal only when they parse to the same tree. One that doesn't parse
      # compares as given, which can keep two equal ones apart but never
      # merges two different ones.
      def normal_expression(expression)
        PgQuery.deparse(PgQuery.parse("SELECT #{expression}").tree).delete_prefix("SELECT ")
      rescue PgQuery::ParseError
        expression
      end

      # The TableName-style pair for a valid assumption's "schema.name".
      def split(name) = name.split(".", 2)
    end
  end
end
