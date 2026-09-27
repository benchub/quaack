# frozen_string_literal: true

module Quaack
  module Enclave
    module RelationQualifier
      # What RelationQualifier raises. Each kind's rule names the check that
      # failed, for ErrorFilter's error line. A plain Error is a name that
      # resolves nowhere.
      class Error < StandardError
        def rule = "unresolved_relation"
      end

      # The plan's search_path can't be read.
      class BadSearchPath < Error
        def rule = "bad_search_path"
      end

      # The query doesn't parse.
      class Unparsable < Error
        def rule = "query_unparsable"
      end
    end
  end
end
