# frozen_string_literal: true

module Quaack
  module Enclave
    module Fuzz
      # Ordinary values for a column's type, by the type's name as
      # format_type gives it, in Postgres's text input form.
      module Typical
        # A long, mixed text value: case, spaces, a dash and digits, past the
        # 12 or so characters that overlay, substring, left and right cut at.
        LONG_TEXT = " Ab-0123456789 xyz "

        VALUES = {
          /\A(smallint|integer|bigint)/ => %w[1 2],
          /\A(numeric|double|real)/ => %w[1.5 2],
          /\Aboolean/ => %w[t f],
          /\Atimestamp/ => ["2024-03-01 10:00:00", "2024-03-02 11:30:00"],
          /\Adate/ => %w[2024-03-01 2024-03-02],
          /\Atime/ => %w[10:00:00 11:30:00],
          /\Ajsonb?\z/ => ["{}", '{"a": 1}'],
          /\Auuid/ => %w[00000000-0000-0000-0000-000000000001 00000000-0000-0000-0000-000000000002],
          /\Ainterval/ => ["1 day", "02:00:00"],
          /\A(inet|cidr)/ => %w[10.0.0.1 10.0.0.2],
          /\Abytea/ => ['\x00', '\x01'],
          /\Abit varying/ => %w[0 1],
          /\Amoney/ => %w[1.00 2.00],
          /\Atsvector/ => %w[a b],
          /\Apoint/ => ["(0,0)", "(1,1)"]
        }.freeze

        TEXT = /\A(text|character|citext|name|"char")/
        NUMBER = /\A(smallint|integer|bigint|numeric|double|real)/

        module_function

        # labels are an enum's, else nil.
        def values(type, labels = nil)
          return labels.first(3) if labels&.any?

          type = type.delete_prefix("pg_catalog.")
          special(type) || VALUES.find { |pattern, _| pattern.match?(type) }&.last || []
        end

        # Arrays, text, and fixed-width bits, whose values depend on the
        # type's details.
        def special(type)
          return ["{}"] if type.end_with?("]")
          return text(type) if type.match?(TEXT)

          bits = type[/\Abit\((\d+)\)/, 1]
          ["0" * Integer(bits), "1" * Integer(bits)] if bits
        end

        def text(type)
          limit = type[/\((\d+)\)/, 1]&.to_i
          limit && limit < LONG_TEXT.size ? %w[a b] : ["a", "b", LONG_TEXT]
        end

        # The nth of a run of distinct values, or nil when the type has none
        # this knows.
        def unique(type, nth)
          case type.delete_prefix("pg_catalog.")
          when NUMBER then (100_000 + nth).to_s
          when /\Atimestamp/ then (Time.utc(2001, 1, 1) + nth).strftime("%F %T")
          when /\Adate/ then (Time.utc(2001, 1, 1) + (nth * 86_400)).strftime("%F")
          when /\Auuid/ then format("10000000-0000-0000-0000-%012d", nth)
          when TEXT then "u#{nth}"
          when /\Ajsonb?\z/ then %({"u": #{nth}})
          end
        end
      end
    end
  end
end
