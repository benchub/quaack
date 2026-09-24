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
      def register(connection) = ErrorFilter.drop_notices(connection)

      # Resets connection and drops its notices again, since the pg gem
      # forgets the receiver on reset. Returns the connection.
      def reset(connection)
        connection.reset
        register(connection)
      end
    end
  end
end
