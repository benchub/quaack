# frozen_string_literal: true

module Quaack
  module Protocol
    # The Postgres major whose grammar the enclave's pg_query parses with
    # (20261009-2). Only a query_unparsable error line carries it, so the
    # driver's note names the enclave's grammar, not its own. It's the
    # enclave's own constant, a plain Integer from 10 to 99, never anything
    # read from a run. The enclave sends it, and the driver keeps it, only if
    # check passes.
    module ParserMajor
      RULE = "query_unparsable"
      MAJORS = (10..99)

      # major, if it's a plain Integer in MAJORS, or nil.
      def self.check(major) = (major if major.instance_of?(Integer) && MAJORS.cover?(major))
    end
  end
end
