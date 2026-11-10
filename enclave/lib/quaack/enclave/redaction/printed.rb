# frozen_string_literal: true

module Quaack
  module Enclave
    module Redaction
      # Each string placeholder's value as Postgres prints it in a plan, for
      # each date and time type it reads as, such as '2026-01-01 00:00:00'
      # for '2026-01-01' as a timestamp, so Matcher can match the plan's
      # literal (20261008-53). One query asks for every value at once, in a
      # read-only transaction with production's DateStyle, IntervalStyle,
      # and TimeZone from inventory, the settings the input EXPLAIN printed
      # with. The texts are value-class: they stay in the enclave, like the
      # placeholder map, and go only to Matcher.
      module Printed
        TYPES = %w[date time timetz timestamp timestamptz interval].freeze
        SETTINGS = %w[DateStyle IntervalStyle TimeZone].freeze
        # Longer text is no date, and isn't worth sending to the server.
        MAX_TEXT = 100
        SET_SQL = "SELECT pg_catalog.set_config($1, $2, true)"
        COLUMNS = TYPES.map do |type|
          "CASE WHEN pg_catalog.pg_input_is_valid(u.v, '#{type}') THEN u.v::pg_catalog.#{type}::pg_catalog.text END"
        end
        SQL = "SELECT #{COLUMNS.join(", ")} FROM pg_catalog.unnest($1::pg_catalog.text[]) " \
              "WITH ORDINALITY AS u(v, i) ORDER BY u.i".freeze

        module_function

        # The values of map's string placeholders that could be a date or
        # time, by number.
        def candidates(map)
          map.filter_map do |key, entry|
            value = entry["value"]
            [Integer(key[1..]), value] if entry["type"] == "unknown" && candidate?(value)
          end.to_h
        end

        def candidate?(value) = value.is_a?(String) && value.length <= MAX_TEXT && value.match?(/\d/)

        # {number => [text, ...]}, each text one the value prints as and its
        # value doesn't already have. connect gives a connection; it's
        # called only when there's a value to ask about. read_only runs the
        # block in a read-only transaction on the connection.
        def of(map, settings:, connect:, read_only:)
          values = candidates(map)
          return {} if values.empty?

          connection = connect.call
          read_only.call(connection) { ask(connection, values, settings) }
        ensure
          connection&.close
        end

        def ask(connection, values, settings)
          set(connection, settings)
          rows = connection.exec_params(SQL, [PG::TextEncoder::Array.new.encode(values.values)]).values
          printed = values.zip(rows).to_h { |(number, value), texts| [number, texts.compact.uniq - [value]] }
          printed.reject { |_, texts| texts.empty? }
        end

        def set(connection, settings)
          SETTINGS.each do |name|
            value = settings[name] if settings.is_a?(Hash)
            connection.exec_params(SET_SQL, [name, value]) if value.is_a?(String) && !value.empty?
          end
        end
      end

      private_constant :Printed
    end
  end
end
