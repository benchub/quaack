# frozen_string_literal: true

module Quaack
  module Protocol
    # A TCP port the operator gives on the command line: `quaack start
    # --port`, which `quaacks intake --port` checks again, and `quaacks
    # run-server --port`. A whole number from 1 to 65535, written with plain
    # ASCII digits and no sign, blank, or leading zero. It's the operator's
    # own configuration, not production data. argv can hold any bytes, so
    # anything that isn't valid ASCII, such as invalid UTF-8 or UTF-16, is
    # refused before the pattern, which would raise on it.
    module Port
      DIGITS = /\A[1-9][0-9]{0,4}\z/
      MAX = 65_535

      module_function

      def valid?(value)
        value.is_a?(String) && value.valid_encoding? && value.ascii_only? && DIGITS.match?(value) &&
          Integer(value, 10) <= MAX
      end
    end
  end
end
