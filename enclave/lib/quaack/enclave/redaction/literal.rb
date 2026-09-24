# frozen_string_literal: true

module Quaack
  module Enclave
    module Redaction
      # What a constant holds and how it's typed. The values are real
      # literals, so nothing here raises with one in its message.
      module Literal
        # Each type class a placeholder's shape can have, by the type names
        # pg_query gives, such as int4 for integer and float8 for double
        # precision. Any other type is "other".
        TYPE_CLASSES = {
          "text" => %w[text varchar bpchar char name citext],
          "integer" => %w[int2 int4 int8 smallint integer int bigint],
          "numeric" => %w[numeric decimal float4 float8 real money],
          "boolean" => %w[bool boolean],
          "datetime" => %w[date time timetz timestamp timestamptz interval]
        }.flat_map { |klass, names| names.map { |name| [name, klass] } }.to_h.freeze

        INT8 = (-(2**63))..((2**63) - 1)

        module_function

        # The constant's value as text, the way the query wrote it, and the
        # type Postgres gives that literal, for PREPARE: an untyped string
        # (and NULL, whose value is nil) is unknown, so it takes its type
        # from where it sits, just as the literal did. A bit string is
        # unknown too, since the type bit alone means bit(1). Its value is
        # pg_query's text, such as b101 or x1F, which bit's input reads.
        def of(constant)
          case constant.val
          when :sval then [constant.sval.sval, "unknown"]
          when :ival then [constant.ival.ival.to_s, "integer"]
          when :fval then [constant.fval.fval, float_type(constant.fval.fval)]
          when :boolval then [constant.boolval.boolval.to_s, "boolean"]
          when :bsval then [constant.bsval.bsval, "unknown"]
          else [nil, "unknown"]
          end
        end

        # pg_query keeps an integer too big for int4 as a Float node, and
        # Postgres types it bigint if it fits, or else numeric.
        def float_type(text)
          number = integer(text)
          number && INT8.cover?(number) ? "bigint" : "numeric"
        end

        # An integer written as Postgres reads one, in decimal, hex, octal,
        # or binary, with underscores, or nil for anything else.
        def integer(text)
          digits = text.delete("_")
          sign = digits.start_with?("-") ? -1 : 1
          digits = digits.delete_prefix("-").delete_prefix("+")
          base = { "0x" => 16, "0o" => 8, "0b" => 2 }.fetch(digits[0, 2].downcase, 10)
          digits = digits[2..] unless base == 10
          sign * Integer(digits, base) if digits.match?(/\A\h+\z/)
        rescue ArgumentError
          nil
        end

        # The type class of an uncast constant.
        def class_of(constant)
          case constant.val
          when :sval then "text"
          when :ival then "integer"
          when :fval then float_type(constant.fval.fval) == "bigint" ? "integer" : "numeric"
          when :boolval then "boolean"
          else "other"
          end
        end

        # The type class of a cast's type. An array's is its element's.
        def type_class(type_name)
          TYPE_CLASSES.fetch(type_name.names.last&.string&.sval.to_s, "other")
        end

        # Where a LIKE pattern has its wildcards, % and _, reading escape as
        # the escape character ("" for none).
        def pattern(text, escape)
          wildcards = pattern_wildcards(text, escape)
          return "no_wildcard" if wildcards.empty?

          { [true, true] => "both_wildcards", [true, false] => "leading_wildcard",
            [false, true] => "trailing_wildcard", [false, false] => "no_wildcard" }
            .fetch([wildcards.first, wildcards.last])
        end

        # One entry per character the pattern matches: true for a wildcard.
        def pattern_wildcards(text, escape)
          chars = text.chars
          wildcards = []
          until chars.empty?
            char = chars.shift
            next wildcards << false.tap { chars.shift } if !escape.empty? && char == escape[0]

            wildcards << %w[% _].include?(char)
          end
          wildcards
        end
      end

      private_constant :Literal
    end
  end
end
