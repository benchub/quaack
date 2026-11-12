# frozen_string_literal: true

module Quaack
  module Enclave
    # SQLSTATE classes and codes that mean the session failed, not the
    # statement: a lost connection, a transaction state error, a rollback, a
    # resource limit, an operator intervention such as a cancel, a system
    # error, a lock not available, or data corruption. The same statement
    # may work next time. SingleCandidateTest and ArenaRunner::Typed share
    # it (task 20261112-100000-1).
    module SessionFailure
      PATTERN = /\A(?:08|25|40|53|57|58)|\A(?:55P03|XX001|XX002)\z/

      module_function

      def match?(sqlstate) = PATTERN.match?(sqlstate)
    end
  end
end
