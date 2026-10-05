# frozen_string_literal: true

module Quaack
  module Enclave
    # The runner's checks of libpq's transaction status, which is local
    # state, so none of them costs a round trip.
    class ArenaRunner
      private

      def refuse_unless_idle
        status = database(:connection_unusable, :transaction) { @connection.transaction_status }
        return if status == PQTRANS_IDLE

        rule = [PQTRANS_INTRANS, PQTRANS_INERROR].include?(status) ? :already_in_transaction : :connection_unusable
        raise Error.new(rule, step: :transaction), cause: nil
      end

      # Raises transaction_ended for step's statement at index unless the
      # status is one of open.
      def refuse_outside_transaction(rule, step, index, open)
        status = database(rule, step, index) { @connection.transaction_status }
        raise Error.new(:transaction_ended, step:, index:), cause: nil unless open.include?(status)
      end
    end
  end
end
