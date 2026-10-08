# frozen_string_literal: true

module Quaack
  module Protocol
    # A database name the operator gives on the command line: `quaack start
    # --database`, which `quaacks intake --database` checks again, and
    # `quaacks run-server --racetrack-db` and `--arena-db`. A plain
    # identifier: a letter, digit, or underscore, then up to 62 more of
    # those or hyphens, so libpq never reads it as a connection string or
    # URI. It's the operator's own configuration, not production data. argv
    # can hold any bytes, so anything that isn't valid ASCII is refused
    # before the pattern, which would raise on it.
    module DatabaseName
      PATTERN = /\A[A-Za-z0-9_][A-Za-z0-9_-]{0,62}\z/

      module_function

      def valid?(value)
        value.is_a?(String) && value.valid_encoding? && value.ascii_only? && PATTERN.match?(value)
      end
    end
  end
end
