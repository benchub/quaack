# frozen_string_literal: true

module Quaack
  module Enclave
    module ResultComparator
      # Reads interval's text output, in any IntervalStyle (postgres,
      # postgres_verbose, sql_standard, or iso_8601), as the value interval's
      # own equality compares: months times 30, plus days, in days, times a
      # day's microseconds, plus the time in microseconds. That's Postgres's
      # interval_cmp_value, so '1 day' equals '24:00:00', and '1 mon' equals
      # '30 days'. The infinities are read as the fields Postgres stores for
      # them, so they compare as Postgres compares them too.
      #
      # Postgres always prints text one of these reads, so any other text
      # means the Result wasn't a real one, and it's refused with a fixed
      # message that names no value.
      module IntervalText
        USECS_PER_DAY = 86_400_000_000
        INFINITIES = {
          "infinity" => [(2**31) - 1, (2**31) - 1, (2**63) - 1], "-infinity" => [-(2**31), -(2**31), -(2**63)]
        }.freeze
        UNREADABLE = "an interval column holds text that isn't an interval"

        # Months in each date unit, and microseconds in each time unit, in
        # the order postgres and postgres_verbose print them. day is days.
        UNITS = { "year" => 12, "mon" => 1, "day" => 1, "hour" => 3_600_000_000, "min" => 60_000_000,
                  "sec" => 1_000_000 }.freeze
        DATE_UNITS = %w[year mon day].freeze

        INTEGER = /\A[+-]?\d+\z/
        SECONDS = /\A[+-]?\d+(?:\.\d+)?\z/
        TIME = /\A([+-]?)(\d+):(\d\d):(\d\d(?:\.\d+)?)\z/
        ISO = /\AP(?:(-?\d+)Y)?(?:(-?\d+)M)?(?:(-?\d+)D)?(?:T(?:(-?\d+)H)?(?:(-?\d+)M)?(?:(-?\d+(?:\.\d+)?)S)?)?\z/
        SQL_EXPLICIT = /\A([+-])(\d+)-(\d+) ([+-]\d+) ([+-])(\d+):(\d\d):(\d\d(?:\.\d+)?)\z/
        SQL_YEAR_MONTH = /\A(-?)(\d+)-(\d+)\z/
        SQL_DAY_TIME = /\A(-?)(?:(\d+) )?(\d+):(\d\d):(\d\d(?:\.\d+)?)\z/

        module_function

        # The value as an Integer.
        def span(text)
          months, days, micros = fields(text)
          (((months * 30) + days) * USECS_PER_DAY) + micros
        end

        # [months, days, microseconds].
        def fields(text)
          read = INFINITIES[text] || iso(text) || verbose(text) || postgres(text) || sql_standard(text)
          raise ArgumentError, UNREADABLE unless read

          read
        rescue ArgumentError, TypeError
          raise ArgumentError, UNREADABLE, cause: nil
        end

        # "P1Y2M-3DT4H5M6.789S", or "PT0S".
        def iso(text)
          match = ISO.match(text) or return
          years, months, days, *time = match.captures
          [(number(years) * 12) + number(months), number(days), time_micros("", *time)]
        end

        # "@ 1 year 2 mons -3 days 4 hours 5 mins 6.789 secs ago", or "@ 0".
        # ago negates every field.
        def verbose(text)
          body = text.delete_prefix("@ ")
          return if body == text
          return [0, 0, 0] if body == "0"

          sign = body.end_with?(" ago") ? -1 : 1
          units(body.delete_suffix(" ago").split, UNITS.keys)&.map { it * sign }
        end

        # "1 year 2 mons -3 days +04:05:06.789", with any part left out.
        def postgres(text)
          tokens = text.split
          time = TIME.match(tokens.last.to_s) ? tokens.pop : nil
          return if tokens.empty? && time.nil?

          date = units(tokens, DATE_UNITS) or return
          [date[0], date[1], time ? time_micros(*TIME.match(time).captures) : 0]
        end

        # "0", "-1-2", "-1 4:05:06", "-4:05:06", or "+1-2 -3 +4:05:06.789".
        # A single leading sign applies to every field.
        def sql_standard(text)
          return [0, 0, 0] if text == "0"

          match = SQL_EXPLICIT.match(text) or return sql_standard_value(text)
          year_sign, years, months, days, *time = match.captures
          [signed(year_sign, (number(years) * 12) + number(months)), number(days), time_micros(*time)]
        end

        def sql_standard_value(text)
          if (match = SQL_YEAR_MONTH.match(text))
            sign, years, months = match.captures
            return [signed(sign, (number(years) * 12) + number(months)), 0, 0]
          end
          match = SQL_DAY_TIME.match(text) or return
          sign, days, *time = match.captures
          [0, signed(sign, number(days)), signed(sign, time_micros("", *time))]
        end

        # Sums "N unit" pairs, each unit at most once, in the order of
        # allowed, into [months, days, microseconds]. A unit may be plural.
        # Only sec may have a fraction. nil when a token isn't one of those.
        def units(tokens, allowed)
          return if tokens.size.odd?

          last = -1
          tokens.each_slice(2).with_object([0, 0, 0]) do |(amount, unit), sums|
            name = unit.delete_suffix("s")
            index = allowed.index(name)
            return nil unless index && index > last && (name == "sec" ? SECONDS : INTEGER).match?(amount)

            last = index
            add(sums, name, amount)
          end
        end

        def add(sums, name, amount)
          if %w[year mon].include?(name) then sums[0] += number(amount) * UNITS[name]
          elsif name == "day" then sums[1] += number(amount)
          else sums[2] += name == "sec" ? micros(amount) : number(amount) * UNITS[name]
          end
        end

        def time_micros(sign, hours, minutes, seconds)
          signed(sign, (number(hours) * UNITS["hour"]) + (number(minutes) * UNITS["min"]) + micros(seconds))
        end

        def signed(sign, value) = sign == "-" ? -value : value

        def number(text) = text.nil? ? 0 : Integer(text, 10)

        # Exact microseconds from seconds' text, such as "-6.789".
        def micros(seconds)
          value = Rational(seconds || "0") * 1_000_000
          raise ArgumentError, UNREADABLE unless value.denominator == 1

          value.to_i
        end
      end
    end
  end
end
