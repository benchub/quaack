# frozen_string_literal: true

require "fileutils"
require "json"

module Quaack
  module Driver
    # The laptop's record of which jump server holds each run, and the
    # production server the operator gave for it, one file per run in
    # ~/.quaack/runs, written by `quaack start`.
    class Runs
      # The enclave's run ID form (Enclave::Store::RUN_ID), checked here too,
      # since it becomes a file name.
      RUN_ID = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/
      # A host name or IPv4 address, the form intake takes for the
      # production server (Enclave::Intake::SERVER), checked again on read,
      # since a note shows it.
      SERVER = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,252}\z/

      def initialize(home)
        @dir = File.join(home, ".quaack", "runs")
      end

      def record(run_id, host, server: nil)
        raise ArgumentError, "not a run ID" unless RUN_ID.match?(run_id)

        FileUtils.mkdir_p(@dir, mode: 0o700)
        File.write(path(run_id), JSON.generate({ "jump_host" => host, "server" => server }.compact))
      end

      # The run's jump host, or nil if this laptop never started it.
      def host(run_id) = read(run_id)&.fetch("jump_host", nil)

      # The run's production server, or nil if this laptop never started it,
      # an older driver did without recording it, or it isn't a host name.
      def server(run_id)
        server = read(run_id)&.fetch("server", nil)
        server if server.is_a?(String) && SERVER.match?(server)
      end

      # The run's jump host and production server, as jump: and server:, for
      # a connection failure's note (EnclaveError#rule_with_note), or nil if
      # this laptop never started it.
      def where(run_id) = (jump = host(run_id)) && { jump:, server: server(run_id) }

      private

      def read(run_id)
        return unless RUN_ID.match?(run_id) && File.file?(path(run_id))

        JSON.parse(File.read(path(run_id)))
      end

      def path(run_id) = File.join(@dir, "#{run_id}.json")
    end
  end
end
