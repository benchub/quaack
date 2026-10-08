# frozen_string_literal: true

module Quaack
  module Enclave
    module NameQualifier
      # What NameQualifier raises, in the "rule: detail" form, so Relations
      # and RewriteCandidateCheck can pass it on.
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end
    end
  end
end
