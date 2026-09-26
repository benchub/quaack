# frozen_string_literal: true

require "fileutils"
require "json"

module Quaack
  module Driver
    # The laptop's record of which jump server holds each run, one file per
    # run in ~/.quaack/runs, written by `quaack start`.
    class Runs
      # The enclave's run ID form (Enclave::Store::RUN_ID), checked here too,
      # since it becomes a file name.
      RUN_ID = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/

      def initialize(home)
        @dir = File.join(home, ".quaack", "runs")
      end

      def record(run_id, host)
        raise ArgumentError, "not a run ID" unless RUN_ID.match?(run_id)

        FileUtils.mkdir_p(@dir, mode: 0o700)
        File.write(path(run_id), JSON.generate("jump_host" => host))
      end

      # The run's jump host, or nil if this laptop never started it.
      def host(run_id)
        return unless RUN_ID.match?(run_id) && File.file?(path(run_id))

        JSON.parse(File.read(path(run_id)))["jump_host"]
      end

      private

      def path(run_id) = File.join(@dir, "#{run_id}.json")
    end
  end
end
