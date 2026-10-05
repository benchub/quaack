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

      # Raises for step's statement at index unless the status is one of
      # open: transaction_ended if the connection is idle or in another
      # transaction state, and connection_unusable if it's busy or has gone
      # bad, as when it died under an earlier statement whose error the
      # caller caught.
      def refuse_outside_transaction(rule, step, index, open)
        status = database(rule, step, index) { @connection.transaction_status }
        return if open.include?(status)

        settled = [PQTRANS_IDLE, PQTRANS_INTRANS, PQTRANS_INERROR].include?(status)
        raise Error.new(settled ? :transaction_ended : :connection_unusable, step:, index:), cause: nil
      end
    end
  end
end
