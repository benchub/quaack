# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/protocol/database_name"
require "quaack/protocol/port"

module Quaack
  module Driver
    # The laptop's record of which jump server holds each run, and the
    # production server and port the operator gave for it, one file per run
    # in ~/.quaack/runs, written by `quaack start`.
    class Runs
      # The enclave's run ID form (Enclave::Store::RUN_ID), checked here too,
      # since it becomes a file name.
      RUN_ID = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/
      # A host name or IPv4 address, the form intake takes for the
      # production server (Enclave::Intake::SERVER), checked again on read,
      # since a note shows it.
      SERVER = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,252}\z/

      # A run record that's there but can't be read, such as one under a
      # ~/.quaack or ~/.quaack/runs it can't read, or one that isn't a
      # file. The message names the record by ~, never by its absolute
      # path.
      class Unreadable < StandardError
        def initialize(run_id, problem) = super("can't read ~/.quaack/runs/#{run_id}.json#{problem}")
      end

      def initialize(home)
        @dir = File.join(home, ".quaack", "runs")
      end

      def record(run_id, host, server: nil, port: nil, database: nil)
        raise ArgumentError, "not a run ID" unless RUN_ID.match?(run_id)

        FileUtils.mkdir_p(@dir, mode: 0o700)
        File.write(path(run_id),
                   JSON.generate({ "jump_host" => host, "server" => server, "port" => port,
                                   "database" => database }.compact))
      end

      # The run's jump host, or nil if this laptop never started it. Each
      # reader reads the record once, and raises Unreadable for a record it
      # can't read, including one whose jump host isn't a string.
      def host(run_id) = where(run_id)&.fetch(:jump)

      # The run's production server, or nil if this laptop never started it,
      # an older driver did without recording it, or it isn't a host name.
      def server(run_id) = where(run_id)&.fetch(:server)

      # The run's production port, the quaack start --port the operator
      # gave, or nil if they gave none, an older driver didn't record it, or
      # it isn't a port (Protocol::Port), checked again on read, since a
      # note shows it.
      def port(run_id) = where(run_id)&.fetch(:port)

      # The run's jump host, production server, port, and database, as
      # jump:, server:, port:, and database: (each checked again on read),
      # all from one read of the record, for a connection failure's note
      # (EnclaveError#rule_with_note), or nil if this laptop never started
      # it.
      def where(run_id)
        record = read(run_id) or return
        jump = record["jump_host"]
        raise Unreadable.new(run_id, " (jump host isn't a string)") unless jump.is_a?(String)

        server, port, database = record.values_at("server", "port", "database")
        { jump:, server: (server if server.is_a?(String) && SERVER.match?(server)),
          port: (port if Protocol::Port.valid?(port)), database: (database if Protocol::DatabaseName.valid?(database)) }
      end

      private

      def read(run_id)
        return unless RUN_ID.match?(run_id) && there?(run_id)

        record = JSON.parse(File.read(path(run_id)))
        raise Unreadable.new(run_id, " (not a JSON object)") unless record.is_a?(Hash)

        record
      rescue JSON::ParserError
        raise Unreadable.new(run_id, " (not valid JSON)")
      rescue Errno::EACCES
        raise Unreadable.new(run_id, " (permission denied)")
      rescue SystemCallError
        raise Unreadable.new(run_id, "")
      end

      # Whether the run's record is there. Unlike File.file?, it raises
      # Unreadable when it can't tell, or when what's there isn't a file.
      def there?(run_id)
        File.stat(path(run_id)).file? or raise Unreadable.new(run_id, "")
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      end

      def path(run_id) = File.join(@dir, "#{run_id}.json")
    end
  end
end
