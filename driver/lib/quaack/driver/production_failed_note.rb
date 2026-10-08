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

      def call(jump, server:, port:, next_step:, database: nil)
        return unknown_port(jump, next_step) unless server || port || database

        "couldn't connect to #{tried(server, port, database)}. QUAACK gives libpq only #{given(port, database)}. " \
          "The #{from_libpq(port, database)} come from #{EnclaveError::LIBPQ_SETUP} " \
          "Test it with #{test_command(jump, server, port, database)}. If production listens on another " \
          "port#{" than your libpq setup gives" unless port}, start a new run with `quaack start --port <n>`. " \
          "Otherwise fix your libpq setup, then #{next_step}"
      end

      # What QUAACK gives libpq, and what comes from the operator's setup.
      def given(port, database)
        parts = ["host", ("port" if port), ("database" if database)].compact
        "that #{parts.size == 3 ? "host, port, and database" : parts.join(" and ")}"
      end

      def from_libpq(port, database)
        parts = [("port" unless port), "user", ("database" unless database), "password"].compact
        "#{parts[0..-2].join(", ")}#{"," if parts.size > 2} and #{parts.last}"
      end

      def unknown_port(jump, next_step)
        "couldn't connect to #{EnclaveError::UNKNOWN_SERVER}. QUAACK gives libpq only that host, and the port " \
          "you gave `quaack start --port`, if you gave one. The user, database, and password, and the port if " \
          "you gave no --port, come from #{EnclaveError::LIBPQ_SETUP} Test it with " \
          "#{test_command(jump, nil, nil)}, adding `-p <n>` if you gave `quaack start --port`. If production " \
          "listens on another port, start a new run with `quaack start --port <n>`. Otherwise fix your libpq " \
          "setup, then #{next_step}"
      end

      # The production server, port, and database the note names.
      def tried(server, port, database)
        "#{server ? "production at #{server}" : EnclaveError::UNKNOWN_SERVER}#{", port #{port}" if port}" \
          "#{", database #{database}" if database}"
      end

      def test_command(jump, server, port, database = nil)
        flags = server ? "#{" -p #{port}" if port}#{" -d #{database}" if database}" : ""
        "`ssh #{jump} 'psql -h #{server || "<server>"}#{flags} -c \"select 1\"'`"
      end
    end
  end
end
