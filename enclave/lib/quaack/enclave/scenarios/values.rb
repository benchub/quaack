# frozen_string_literal: true

require "date"
require "pg"
require_relative "literals"

module Quaack
  module Enclave
    module Scenarios
      # Values for columns no atom constrains: a type's typical value (0,
      # '', the epoch, an empty range or array) and its nth distinct value,
      # for keys and unique columns. Each is checked against the type in
      # Postgres, and the first one it reads is used.
      #
      # The nth value of a range is the range holding just the subtype's
      # nth value, and of an array the array holding just the element
      # type's. A bit(n) is padded to its length. A smallint, an integer,
      # or a numeric with a precision keeps its nth value in range: past
      # the largest it fits, the number wraps to a negative one, so a split
      # group's key (Builder#key_value) still differs from the others.
      class Values
        EPOCH = Date.new(1970, 1, 1)

        TYPICAL = {
          "N" => ["0"], "S" => [""], "B" => ["f"],
          "D" => ["1970-01-01 00:00:00+00", "00:00:00"], "T" => ["0"], "R" => ["empty"],
          "G" => ["(0,0)", "((0,0),(0,0))", "<(0,0),0>", "{1,-1,0}"]
        }.freeze

        FALLBACK = ["0", "", "{}", "00000000-0000-0000-0000-000000000000", "0.0.0.0", "\\x"].freeze

        MANY = %w[N S D T U I].freeze
        FEW = %w[B E V].freeze

        INFO_SQL = <<~SQL
          SELECT t.typcategory, NULLIF(t.typelem, 0)::int, r.rngsubtype::int, format_type(r.rngsubtype, NULL)
          FROM pg_type t LEFT JOIN pg_range r ON r.rngtypid = t.oid
          WHERE t.oid = $1
        SQL

        # What the catalog says about a type: its category, its element type
        # (an array's) or subtype (a range's) as a Column, if any.
        TypeInfo = Data.define(:category, :inner)

        def initialize(conn)
          @conn = conn
          @types = {}
          @readable = {}
        end

        # With strict: false, nil when the type reads none of them, as for
        # a domain whose CHECK the caller satisfies some other way.
        def typical(col, strict: true)
          return labels(col).first if category(col) == "E"

          candidates = typicals(col) + FALLBACK
          strict ? first_readable(col, candidates) : candidates.find { |v| readable?(col, v) }
        end

        def nth(col, number)
          if category(col) == "E"
            labels = labels(col)
            return labels[number % labels.size] unless labels.empty?
          end

          first_readable(col, nths(col, number))
        end

        # How well the type takes distinct values, lowest best: numbers,
        # text, times, uuids, and network addresses first, then the rest,
        # then booleans, enums, and bit strings, which have few.
        def rank(col)
          return 0 if MANY.include?(category(col))

          FEW.include?(category(col)) ? 2 : 1
        end

        # Whether the column's type reads value. Keyed by the type as
        # format_type prints it, typmod and all: bit(4) and bit(8) share an
        # oid but not their values.
        def readable?(col, value)
          @readable.fetch([col.type, value]) do
            @conn.exec_params("SELECT CAST($1 AS #{col.type})", [value])
            @readable[[col.type, value]] = true
          rescue PG::Error
            @readable[[col.type, value]] = false
          end
        end

        private

        def typicals(col)
          return [Literals.bits(col.type, 0)] if category(col) == "V"

          TYPICAL.fetch(category(col), [])
        end

        def nths(col, number)
          case category(col)
          when "N" then [Literals.numeric(col.type, number)]
          when "S" then ["k#{number}", number.to_s]
          when "D" then [(EPOCH + number).to_s, format("00:00:%<s>02d", s: number % 60)]
          when "B" then [number.odd? ? "t" : "f"]
          when "T" then ["#{number} seconds"]
          else structured_nths(col, number)
          end
        end

        def structured_nths(col, number)
          case category(col)
          when "A" then wrapped(col, number) { |v| "{#{v}}" }
          when "R" then wrapped(col, number) { |v| "[#{v},#{v}]" }
          when "G" then Literals.geometric(number)
          when "V" then [Literals.bits(col.type, number)]
          else Literals.others(number)
          end
        end

        # The inner type's nth value, double-quoted, inside an array or
        # range, or none when the inner type has no nth value.
        def wrapped(col, number)
          inner = info(col).inner
          return [] unless inner

          value = nth(inner, number)
          [yield("\"#{value.gsub(/["\\]/) { "\\#{it}" }}\"")]
        rescue Error
          []
        end

        def first_readable(col, candidates)
          candidates.find { |v| readable?(col, v) } || raise(Error, :unsupported_type)
        end

        def category(col) = info(col).category

        def info(col)
          @types[[col.oid, col.type]] ||= begin
            category, element, subtype, subtype_name = @conn.exec_params(INFO_SQL, [col.oid]).values.first
            TypeInfo.new(category:, inner: inner(col, category, element, subtype, subtype_name))
          end
        end

        # An array's element type, with the column's typmod, or a range's
        # subtype.
        def inner(col, category, element, subtype, subtype_name)
          if category == "A" && element && col.type.end_with?("[]")
            col.with(type: col.type.sub(/(\[\])+\z/, ""), oid: Integer(element))
          elsif category == "R" && subtype
            col.with(type: subtype_name, oid: Integer(subtype))
          end
        end

        def labels(col)
          @conn.exec_params("SELECT enumlabel FROM pg_enum WHERE enumtypid = $1 ORDER BY enumsortorder",
                            [col.oid]).column_values(0)
        end
      end
    end
  end
end
