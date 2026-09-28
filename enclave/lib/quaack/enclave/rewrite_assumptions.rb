# frozen_string_literal: true

module Quaack
  module Enclave
    # The structured assumptions a rewrite states (DESIGN.md 6a), and their
    # vocabulary, which is exactly these four kinds:
    #
    #   { "kind" => "not_null", "table" => "public.orders", "column" => "id" }
    #   { "kind" => "unique", "table" => "public.orders", "columns" => ["id"] }
    #   { "kind" => "foreign_key", "table" => "public.orders", "columns" => ["customer_id"],
    #     "references_table" => "public.customers", "references_columns" => ["id"] }
    #   { "kind" => "check", "table" => "public.orders", "expression" => "total >= 0" }
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
        "check" => { "table" => :name, "expression" => :string }
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

      # The TableName-style pair for a valid assumption's "schema.name".
      def split(name) = name.split(".", 2)
    end
  end
end
