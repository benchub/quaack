# frozen_string_literal: true

require "date"
require_relative "error"

module Quaack
  module Enclave
    module Intake
      # The run's clock anchor (DESIGN.md, 3h): the time the production plan
      # ran, which quaack.clock_anchor() returns in place of now() and its
      # kin. It's --captured-at if the operator gives it, and the time of
      # intake if not. The run stores it in UTC, to the microsecond, as
      # Postgres keeps a timestamptz: 2026-09-23T22:15:00.000000Z.
      module ClockAnchor
        # An ISO-8601 time with a zone, such as 2026-09-23T22:15:00Z or
        # 2026-09-23T15:15:00.25-07:00. Seconds are required, and so is the
        # zone: a time without one means whatever the jump server's zone is.
        # Digits past the microsecond are dropped.
        FORM = /\A(?<year>\d{4})-(?<month>\d\d)-(?<day>\d\d)
                T(?<hour>\d\d):(?<minute>\d\d):(?<second>\d\d)(?:\.(?<fraction>\d{1,9}))?
                (?<zone>Z|[+-](?<zone_hour>\d\d):(?<zone_minute>\d\d))\z/x

        # The earliest time --captured-at may give.
        EARLIEST = Time.utc(1970).freeze
        # How far past the moment of intake --captured-at may be, in
        # seconds, for a jump server whose clock runs a little slow. A plan
        # can't have run any later than that.
        FUTURE_SLACK = 86_400

        module_function

        def from(captured_at, now: Time.now)
          time = captured_at.nil? ? now : bounded(parse(captured_at), now)
          time.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
        end

        # Raises Error with bad_captured_at for a time before 1970, or more
        # than FUTURE_SLACK after now. That also keeps the year within what
        # Postgres writes as four digits.
        def bounded(time, now)
          raise Error, "bad_captured_at" if time < EARLIEST || time > now + FUTURE_SLACK

          time
        end

        # Raises Error with bad_captured_at for anything but FORM, or for a
        # time that doesn't exist, such as February 30, 24:00, or a leap
        # second, which Ruby would roll into the next day or minute.
        def parse(text)
          match = FORM.match(text) if text.is_a?(String) && text.ascii_only?
          raise Error, "bad_captured_at" unless match

          parts = numbers(match)
          raise Error, "bad_captured_at" unless exists?(parts)

          Time.new(*parts.values_at(:year, :month, :day, :hour, :minute),
                   parts[:second] + microseconds(match[:fraction]), match[:zone])
        end

        # Each numeric part as an Integer, with 0 for a zone of Z.
        def numbers(match)
          match.named_captures(symbolize_names: true).except(:fraction, :zone)
               .transform_values { Integer(it || "0", 10) }
        end

        # Each part below its limit: hour 24, minute and second 60, and the
        # zone's hour 24 and minute 60.
        def exists?(parts)
          Date.valid_date?(*parts.values_at(:year, :month, :day)) &&
            parts.values_at(:hour, :minute, :second, :zone_hour, :zone_minute).zip([24, 60, 60, 24, 60])
                 .all? { |part, limit| part < limit }
        end

        def microseconds(fraction) = Rational(Integer((fraction || "").ljust(6, "0")[0, 6], 10), 1_000_000)
      end
    end
  end
end
