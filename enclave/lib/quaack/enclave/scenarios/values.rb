# frozen_string_literal: true

require "date"
require "pg"

module Quaack
  module Enclave
    module Scenarios
      # Values for columns no atom constrains: a type's typical value (0,
      # '', the epoch) and its nth distinct value, for keys and unique
      # columns. Each is checked against the type in Postgres, and the
      # first one it reads is used.
      class Values
        EPOCH = Date.new(1970, 1, 1)

        TYPICAL = {
          "N" => ["0"], "S" => [""], "B" => ["f"],
          "D" => ["1970-01-01 00:00:00+00", "00:00:00"], "T" => ["0"]
        }.freeze

        FALLBACK = ["0", "", "{}", "00000000-0000-0000-0000-000000000000", "0.0.0.0", "\\x"].freeze

        def initialize(conn)
          @conn = conn
          @categories = {}
          @readable = {}
        end

        def typical(col)
          return labels(col).first if category(col) == "E"

          first_readable(col, TYPICAL.fetch(category(col), []) + FALLBACK)
        end

        def nth(col, number)
          return labels(col)[number % labels(col).size] if category(col) == "E"

          first_readable(col, nths(category(col), number))
        end

        private

        def nths(category, number)
          case category
          when "N" then [number.to_s]
          when "S" then ["k#{number}", number.to_s]
          when "D" then [(EPOCH + number).to_s, format("00:00:%<s>02d", s: number % 60)]
          when "B" then [number.odd? ? "t" : "f"]
          when "T" then ["#{number} seconds"]
          else others(number)
          end
        end

        # uuid, json, inet, bytea, and anything else that reads one.
        def others(number)
          [format("00000000-0000-0000-0000-%<n>012d", n: number), number.to_s, "{\"k\": #{number}}",
           "10.#{number / 65_536 % 256}.#{number / 256 % 256}.#{number % 256}", format("\\x%<n>02x", n: number % 256)]
        end

        def first_readable(col, candidates)
          candidates.find { |v| readable?(col, v) } || raise(Error, :unsupported_type)
        end

        def readable?(col, value)
          @readable.fetch([col.oid, value]) do
            @conn.exec_params("SELECT CAST($1 AS #{col.type})", [value])
            @readable[[col.oid, value]] = true
          rescue PG::Error
            @readable[[col.oid, value]] = false
          end
        end

        def category(col)
          @categories[col.oid] ||= @conn.exec_params("SELECT typcategory FROM pg_type WHERE oid = $1",
                                                     [col.oid]).getvalue(0, 0)
        end

        def labels(col)
          @conn.exec_params("SELECT enumlabel FROM pg_enum WHERE enumtypid = $1 ORDER BY enumsortorder",
                            [col.oid]).column_values(0)
        end
      end
    end
  end
end
