# frozen_string_literal: true

require "date"
require "pg"
require_relative "literals"
require_relative "types"

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
      # or a numeric with a precision, or a domain over one, keeps its nth
      # value in range: past the largest it fits, the number wraps to a
      # negative one, so a split group's key (Builder#key_value) still
      # differs from the others. A column whose type reads no candidate is
      # refused (see refusal).
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

        def initialize(conn)
          @conn = conn
          @types = Types.new(conn)
          @readable = {}
        end

        # nil when the type reads none of them, as for a domain whose CHECK
        # the caller satisfies some other way.
        def typical(col)
          return labels(col).first if category(col) == "E"

          (typicals(col) + FALLBACK).find { |v| readable?(col, v) }
        end

        # table is the column's table, which a refusal names.
        def nth(col, number, table: nil)
          if category(col) == "E"
            labels = labels(col)
            return labels[number % labels.size] unless labels.empty?
          end

          candidates = nths(col, number)
          candidates.find { |v| readable?(col, v) } || raise(refusal(col, table, candidates))
        end

        # The nth value of the first of columns ([table, Column] pairs, such
        # as a key slot's) that every one of them reads, so a smallint and
        # an integer joined take a value both hold.
        def shared_nth(columns, number)
          values = columns.map { |table, col| nth(col, number, table:) }
          values.find { |v| columns.all? { |_, col| readable?(col, v) } } || values.first
        end

        # The error for a column of table whose type reads none of
        # candidates: domain_check for a domain whose base type reads one,
        # so the domain's CHECK rejected them, and unsupported_type
        # otherwise. It names the table, column, and type, which are schema.
        def refusal(col, table, candidates = typicals(col) + FALLBACK)
          base = info(col).base
          rule = base && candidates.any? { readable?(base, it) } ? :domain_check : :unsupported_type
          Error.new(rule, column: { "table" => table.to_s, "column" => col.name, "type" => col.type })
        end

        # How well the type takes distinct values, lowest best: numbers,
        # text, times, uuids, and network addresses first, then the rest,
        # then booleans, enums, and bit strings, which have few, and last a
        # type with no distinct value it reads, such as pg_lsn.
        def rank(col)
          return 3 unless distinct?(col)
          return 0 if MANY.include?(category(col))

          FEW.include?(category(col)) ? 2 : 1
        end

        # Whether the column's type reads value as an insert of it does:
        # the type's input function with its typmod, so a varchar(n) value
        # that's too long fails rather than being cut short, as a CAST
        # would. A domain's CHECKs apply too. Keyed by the type as
        # format_type prints it, typmod and all: bit(4) and bit(8) share an
        # oid but not their values.
        def readable?(col, value)
          @readable.fetch([col.type, value]) do
            @readable[[col.type, value]] =
              @conn.exec_params("SELECT pg_catalog.pg_input_is_valid($1, $2)", [value, col.type]).getvalue(0, 0) == "t"
          rescue PG::Error
            @readable[[col.type, value]] = false
          end
        end

        # Whether the type takes NULL: no domain under it is NOT NULL.
        def nullable_type?(col) = !info(col).not_null

        # Whether the type has an nth value it reads.
        def distinct?(col)
          nth(col, 1)
          true
        rescue Error
          false
        end

        private

        def typicals(col)
          return [Literals.bits(underlying(col).type, 0)] if category(col) == "V"

          TYPICAL.fetch(category(col), [])
        end

        def nths(col, number)
          case category(col)
          when "N" then [Literals.numeric(underlying(col).type, number)]
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
          when "V" then [Literals.bits(underlying(col).type, number)]
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

        def category(col) = @types.category(col)
        def underlying(col) = @types.underlying(col)
        def info(col) = @types.info(col)
        def labels(col) = @types.labels(col)
      end
    end
  end
end
