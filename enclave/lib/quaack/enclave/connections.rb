# frozen_string_literal: true

require_relative "error_filter"

module Quaack
  module Enclave
    # The one way a step takes a database connection, production, racetrack,
    # or arena alike. A notice, such as a RAISE NOTICE in a stable function,
    # can print a row value, and libpq's default receiver writes it to
    # stderr, which goes back over ssh. So every connection a step opens goes
    # through register before its first query, and every reset goes through
    # reset. Inventory::Production opens production connections; this only
    # makes them quiet.
    #
    # It duck types the connection, so this file doesn't need the pg gem.
    module Connections
      module_function

      # Drops every notice on connection (see ErrorFilter.drop_notices).
      # Returns the connection.
      # It also remembers the connection, weakly, for cancel_all.
      def register(connection)
        OPEN[connection] = true
        ErrorFilter.drop_notices(connection)
      end

      # Every connection register has seen and that is still alive.
      OPEN = ObjectSpace::WeakMap.new

      # Cancels whatever each registered connection is running, as when the
      # driver has gone away (see Hangup). A connection that is closed, idle,
      # or fails to cancel is skipped. Cancelling makes the running statement
      # fail, which aborts its transaction.
      def cancel_all
        OPEN.each_key do |connection|
          connection.cancel
        rescue StandardError
          nil
        end
      end

      # Resets connection and drops its notices again, since the pg gem
      # forgets the receiver on reset. Returns the connection.
      def reset(connection)
        connection.reset
        register(connection)
      end
    end
  end
end
