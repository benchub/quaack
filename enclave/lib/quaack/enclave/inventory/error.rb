# frozen_string_literal: true

module Quaack
  module Enclave
    module Inventory
      # A failed production inventory. The CLI sends it as an error line with
      # its rule and, for an error Postgres reported, the SQLSTATE (see
      # ErrorFilter). Its message is the rule alone, and it's always raised
      # with no cause: a libpq or Postgres message can name the host, the
      # user, or a value, and a memory command's output is the operator's.
      class Error < StandardError
        attr_reader :rule, :sqlstate

        def initialize(rule, sqlstate: nil)
          @rule = rule
          @sqlstate = sqlstate
          super(rule)
        end
      end
    end
  end
end
