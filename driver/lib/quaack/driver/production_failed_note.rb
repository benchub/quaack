# frozen_string_literal: true

module Quaack
  module Driver
    # production_connection_failed's note (EnclaveError#rule_with_note),
    # after the rule: the production server and port tried, where the rest
    # of the connection comes from, how to test it from jump, and what to do
    # next. server and port are the ones the run recorded, or nil.
    #
    # The port is in the test command only when the run recorded one, and
    # the server too, so the command is never half filled in. Drivers
    # before 0.1.6 recorded neither, but gave intake quaack start --port,
    # whose port the enclave connects with, so with neither recorded the
    # note can't say whether the port came from --port or libpq.
    module ProductionFailedNote
      module_function

      def call(jump, server, port, next_step)
        return unknown_port(jump, next_step) unless server || port

        "couldn't connect to #{tried(server, port)}. QUAACK gives libpq only that host#{" and port" if port}. " \
          "The #{"port, " unless port}user, database, and password come from #{EnclaveError::LIBPQ_SETUP} " \
          "Test it with #{test_command(jump, server, port)}. If production listens on another " \
          "port#{" than your libpq setup gives" unless port}, start a new run with `quaack start --port <n>`. " \
          "Otherwise fix your libpq setup, then #{next_step}"
      end

      def unknown_port(jump, next_step)
        "couldn't connect to #{EnclaveError::UNKNOWN_SERVER}. QUAACK gives libpq only that host, and the port " \
          "you gave `quaack start --port`, if you gave one. The user, database, and password, and the port if " \
          "you gave no --port, come from #{EnclaveError::LIBPQ_SETUP} Test it with " \
          "#{test_command(jump, nil, nil)}, adding `-p <n>` if you gave `quaack start --port`. If production " \
          "listens on another port, start a new run with `quaack start --port <n>`. Otherwise fix your libpq " \
          "setup, then #{next_step}"
      end

      # The production server and port the note names.
      def tried(server, port)
        "#{server ? "production at #{server}" : EnclaveError::UNKNOWN_SERVER}#{", port #{port}" if port}"
      end

      def test_command(jump, server, port)
        "`ssh #{jump} 'psql -h #{server || "<server>"}#{" -p #{port}" if server && port} -c \"select 1\"'`"
      end
    end
  end
end
