# frozen_string_literal: true

require "json"
require "shellwords"
require_relative "enclave_version"
require_relative "runs"
require_relative "transport/child"
require_relative "transport/ssh"

module Quaack
  module Driver
    # `quaack start --server <prod> --query <file> --plan <file>` (README,
    # "Where QUAACK runs" and step 1). The query and plan paths are on the
    # jump server, and their files never leave it.
    #
    # It finds the jump server with jump_command from the driver config,
    # ~/.quaack/driver.json on the laptop: a one-line shell command in which
    # every {server} becomes the production server name, as one shell word.
    # /bin/sh runs it with no stdin and its stderr thrown away, and it must
    # print one ssh host (Transport::Ssh::HOST), with blank space around it
    # allowed. Then it runs `quaacks intake` there over ssh, and records the
    # run's jump host in ~/.quaack/runs/<run ID>.json, so later commands take
    # only the run ID. It returns the run ID.
    class Start
      # A failure, whose message is its rule. The command's output is never
      # in one.
      class Error < StandardError; end

      # Seconds, as for the enclave's memory_command.
      JUMP_TIMEOUT = 30
      MAX_OUTPUT = 256
      SERVER = "{server}"

      def initialize(home: Dir.home, ssh: "ssh", jump_timeout: JUMP_TIMEOUT)
        @home = home
        @ssh = ssh
        @jump_timeout = jump_timeout
      end

      def call(server:, query:, plan:)
        host = jump_host(jump_command, server)
        transport = Transport::Ssh.new(host:, ssh: @ssh)
        EnclaveVersion.check!(transport, host)
        result = transport.call("intake", args: { query:, plan:, server: })
        run_id = result.messages.find { it["type"] == "run" }&.fetch("run_id", nil)
        raise Error, "bad_run_id" unless run_id.is_a?(String) && Runs::RUN_ID.match?(run_id)

        Runs.new(@home).record(run_id, host)
        run_id
      end

      private

      def jump_command
        path = File.join(@home, ".quaack", "driver.json")
        raise Error, "no_driver_config" unless File.file?(path)

        command = begin
          JSON.parse(File.read(path))
        rescue JSON::ParserError
          nil
        end
        command = command["jump_command"] if command.is_a?(Hash)
        raise Error, "bad_driver_config" unless command.is_a?(String) && command.match?(/\A[^\n\r]*\S[^\n\r]*\z/)

        command
      end

      def jump_host(template, server)
        command = template.gsub(SERVER) { Shellwords.escape(server) }
        run = Transport::Child.run(["/bin/sh", "-c", command], stdin: nil, timeout: @jump_timeout,
                                                               max_output_bytes: MAX_OUTPUT)
        raise Error, "jump_command_timed_out" if run.limit == :timeout
        raise Error, "jump_command_bad_output" if run.limit
        raise Error, "jump_command_failed" unless run.status.success?

        host = run.stdout.strip
        raise Error, "jump_command_bad_output" unless Transport::Ssh::HOST.match?(host)

        host
      end
    end
  end
end
