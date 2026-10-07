# frozen_string_literal: true

module Quaack
  module Enclave
    # IndexBuild's connection: its settings, and its guards against an
    # orphaned build (20261006-9). When a per-index call times out, the
    # driver kills ssh, but the server can keep running its CREATE INDEX.
    # check_client makes the server stop it soon after, and a resume
    # cancels it first (cancel_orphans) rather than racing it to a
    # duplicate name.
    module BuildConnection
      WAIT = 30

      # Postgres 14 and up check this often that the client is still there,
      # so a build whose client was killed stops soon after instead of
      # running on unseen.
      CLIENT_CHECK = "2s"

      module_function

      # Sets IndexBuild::SETTINGS, then check_client.
      def configure(connection)
        IndexBuild::SETTINGS.each { |k, v| connection.exec("SET #{k} = '#{v}'") }
        check_client(connection)
      end

      # Sets client_connection_check_interval to CLIENT_CHECK, where the
      # server has it.
      def check_client(connection)
        return if connection.server_version < 140_000

        connection.exec("SET client_connection_check_interval = '#{CLIENT_CHECK}'")
      end

      # Cancels any other backend still building name, such as one whose
      # client the driver's timeout killed, and waits up to WAIT
      # seconds for it to stop. Its client is gone, so nobody reads its
      # result, and waiting it out could cost the resume's whole timeout.
      # Only QUAACK names an index quaack_ and a DDL hash, so this never
      # touches someone else's build.
      def cancel_orphans(connection, name)
        deadline = now + WAIT
        until (pids = builders(connection, name)).empty?
          raise IndexBuild::Error, "index_build_orphan_running" if now > deadline

          pids.each { connection.exec_params("SELECT pg_cancel_backend($1)", [it]) }
          sleep 0.1
        end
      end

      def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # A fresh transaction each call, so pg_stat_activity isn't the
      # snapshot an open transaction keeps.
      def builders(connection, name)
        connection.exec_params(<<~SQL, ["CREATE INDEX #{name} %"]).column_values(0)
          SELECT pid FROM pg_stat_activity
          WHERE pid <> pg_backend_pid() AND datname = current_database() AND state = 'active' AND query LIKE $1
        SQL
      end
    end
  end
end
