# frozen_string_literal: true

module Quaack
  module Enclave
    # What IndexCandidate and the SQL parsing behind it (IndexSql,
    # IndexKeySql, and IndexMethods) raise for a definition they refuse.
    # It's IndexCandidate::Error: it lives in its own file so those helpers,
    # which IndexCandidate loads first, can raise it. Its rule is fixed, for
    # ErrorFilter's error line, and no message quotes a predicate or an
    # expression.
    class IndexCandidateError < StandardError
      def rule = "invalid_index_candidate"
    end
  end
end
