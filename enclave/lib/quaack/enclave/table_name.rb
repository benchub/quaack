# frozen_string_literal: true

module Quaack
  module Enclave
    # A schema-qualified table name, shared by IndexCandidate and the
    # statistics input so a generator can look up the statistics for the
    # table it's proposing an index on. Both parts are the real catalog
    # names, unquoted: "Order Items" is stored as is, not as "\"Order Items\"".
    TableName = Data.define(:schema, :name) do
      def initialize(schema:, name:)
        { schema:, name: }.each do |part, value|
          raise ArgumentError, "table #{part} must be a non-empty String" unless value.is_a?(String) && !value.empty?
        end
        super(schema: schema.dup.freeze, name: name.dup.freeze)
      end

      # For messages only. It isn't quoted, so never put it in SQL.
      def to_s = "#{schema}.#{name}"
    end
  end
end
