# frozen_string_literal: true

require "json"

module Quaack
  module Driver
    module LLM
      # Checks a parsed reply against a JSON schema, but only as far as
      # callers lean on it: the reply is an object, and each required
      # top-level key is there with the JSON type (array, object, or string)
      # its property names. It isn't a full JSON schema validator.
      #
      #   ReplyShape.matches?({ "ddl" => [] }, schema)   # => true
      module ReplyShape
        TYPES = { "array" => Array, "object" => Hash, "string" => String }.freeze

        # A nil schema matches anything.
        def self.matches?(value, schema)
          return true unless schema
          return false unless value.is_a?(Hash)

          schema = JSON.parse(JSON.generate(schema))
          props = schema.fetch("properties", {})
          schema.fetch("required", []).all? do |key|
            value.key?(key) && type?(value[key], props.dig(key, "type"))
          end
        end

        def self.type?(value, type)
          klass = TYPES[type] or return true
          value.is_a?(klass)
        end
      end
    end
  end
end
