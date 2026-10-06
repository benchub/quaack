# frozen_string_literal: true

module Quaack
  module Enclave
    # The runner's checks of libpq's transaction status, which is local
    # state, so none of them costs a round trip.
    class ArenaRunner
      private

      def refuse_unless_idle
        status = database(:connection_unusable, :transaction) { @connection.transaction_status }
        return if status == PG::PQTRANS_IDLE

        in_transaction = [PG::PQTRANS_INTRANS, PG::PQTRANS_INERROR].include?(status)
        rule = in_transaction ? :already_in_transaction : :connection_unusable
        raise Error.new(rule, step: :transaction), cause: nil
      end

      # Raises for step's statement at index unless the status is one of
      # open: transaction_ended if the connection is idle, so the
      # transaction has ended, and connection_unusable otherwise: it's busy
      # or has gone bad, as when it died under an earlier statement whose
      # error the caller caught, or it reports an aborted transaction after
      # a statement that succeeded, which can't happen on a sound connection.
      def refuse_outside_transaction(rule, step, index, open)
        status = database(rule, step, index) { @connection.transaction_status }
        return if open.include?(status)

        refusal = status == PG::PQTRANS_IDLE ? :transaction_ended : :connection_unusable
        raise Error.new(refusal, step:, index:), cause: nil
      end
    end
  end
end
