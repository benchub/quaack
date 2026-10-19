# frozen_string_literal: true

require "time"
require_relative "format"

module Quaack
  module Driver
    module Report
      # The times the report shows: how long a wait was, and when the
      # report was generated (@generated_at, a UTC Time).
      module Times
        # A wait in seconds: "12.3 s", or "1 min 1.5 s" from a minute on.
        def wait(seconds)
          minutes, rest = seconds.divmod(60)
          minutes.zero? ? Format.decimal(rest, "s") : "#{Format.number(minutes.to_i)} min #{Format.decimal(rest, "s")}"
        end

        # When the report was generated, for the line under the title: ISO
        # 8601 for the template's script, which shows it in the reader's
        # locale and time zone, and UTC for a reader whose browser runs no
        # script.
        def generated_iso = @generated_at.iso8601
        def generated_utc = @generated_at.strftime("%Y-%m-%d %H:%M UTC")
      end
    end
  end
end
