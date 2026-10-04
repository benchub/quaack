# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # The nth distinct literal of a type, worked out from the type's name
      # alone, for Values to check against Postgres.
      module Literals
        # The largest whole number each narrow integer type holds.
        INTEGER_MAX = { "smallint" => 32_767, "integer" => 2_147_483_647 }.freeze
        NUMERIC = /\Anumeric\((?<precision>\d+)(?:,(?<scale>\d+))?\)\z/
        BIT = /\Abit(?<varying> varying)?(?:\((?<length>\d+)\))?\z/

        module_function

        # number, in units of the type's scale, wrapped to a negative number
        # when it's past the largest the type holds.
        def numeric(type, number)
          max, scale = narrow(type)
          return number.to_s unless max

          scaled(number <= max ? number : -(((number - max - 1) % max) + 1), scale)
        end

        def scaled(units, scale)
          return units.to_s if scale.zero?

          whole, fraction = units.abs.divmod(10**scale)
          "#{"-" if units.negative?}#{whole}.#{fraction.to_s.rjust(scale, "0")}"
        end

        # The largest number of units a narrow numeric type holds, and its
        # scale, or nil for a wide one.
        def narrow(type)
          return [INTEGER_MAX[type], 0] if INTEGER_MAX.key?(type)

          match = NUMERIC.match(type)
          [(10**Integer(match[:precision])) - 1, Integer(match[:scale] || 0)] if match
        end

        # number in binary, the last bits of it that fit the length, padded
        # to it for a bit(n). A bit varying with no length takes it whole.
        def bits(type, number)
          match = BIT.match(type)
          return number.to_s(2) if match[:varying] && !match[:length]

          length = Integer(match[:length] || 1)
          value = (number % (2**length)).to_s(2)
          match[:varying] ? value : value.rjust(length, "0")
        end

        # Polygons and paths read the point form too, as one point, so the
        # forms with more points come first.
        def geometric(number)
          ["((0,0),(#{number + 1},0),(0,1))", "((0,0),(#{number + 1},1))", "<(0,0),#{number + 1}>",
           "{1,-1,#{number}}", "(#{number},0)"]
        end

        # uuid, json, inet, bytea, and anything else that reads one.
        def others(number)
          [format("00000000-0000-0000-0000-%<n>012d", n: number), number.to_s, "{\"k\": #{number}}",
           "10.#{number / 65_536 % 256}.#{number / 256 % 256}.#{number % 256}", format("\\x%<n>02x", n: number % 256)]
        end
      end
    end
  end
end
