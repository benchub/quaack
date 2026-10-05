# frozen_string_literal: true

require "json"
require "pathname"
require "shellwords"
require "quaack/protocol/port"
require_relative "driver_config"
require_relative "enclave_version"
require_relative "runs"
require_relative "transport/child"
require_relative "transport/ssh"

module Quaack
  module Driver
    # `quaack start --server <prod> --query <file> --plan <file> [--port <n>]`
    # (DESIGN.md, "Where QUAACK runs" and input). The query and plan paths
    # are on the jump server, and their files never leave it. --port is
    # production's port, for a server that doesn't listen where the
    # operator's libpq setup on the jump server points. It's checked here,
    # as run-server's --port is (Protocol::Port), and passed to intake,
    # which checks it again. Without it, libpq's setup picks the port.
    #
    # It finds the jump server with jump_command from the driver config,
    # ~/.quaack/driver.json on the laptop: a one-line shell command in which
    # every {server} becomes the production server name, as one shell word.
    # /bin/sh runs it with no stdin and its stderr thrown away, and it must
    # print one ssh host (Transport::Ssh::HOST), with blank space around it
    # allowed. Then it runs `quaacks intake` there over ssh, and records the
    # run's jump host, production server and port in
    # ~/.quaack/runs/<run ID>.json, so later commands take only the run ID,
    # and a connection failure's note can name the server and port. It
    # returns the run ID.
    class Start
      # A failure, whose message is its rule. The command's output is never
      # in one.
      class Error < StandardError; end
      class UsageError < Error; end

      # Seconds, as for the enclave's memory_command.
      JUMP_TIMEOUT = 30
      MAX_OUTPUT = 256
      SERVER = "{server}"

      def initialize(home: Dir.home, ssh: "ssh", jump_timeout: JUMP_TIMEOUT)
        @home = home
        @ssh = ssh
        @jump_timeout = jump_timeout
      end

      def call(server:, query:, plan:, port: nil)
        args = intake_args(server:, query:, plan:, port:)
        host = jump_host(jump_command, server)
        transport = Transport::Ssh.new(host:, ssh: @ssh)
        EnclaveVersion.check!(transport, host)
        run_id = transport.call("intake", args:).messages.find { it["type"] == "run" }&.fetch("run_id", nil)
        raise Error, "bad_run_id" unless run_id.is_a?(String) && Runs::RUN_ID.match?(run_id)

        Runs.new(@home).record(run_id, host, server:, port:)
        run_id
      end

      private

      # intake's arguments, once each is checked: --port only when given.
      def intake_args(server:, query:, plan:, port:)
        check_remote_path!("query", query)
        check_remote_path!("plan", plan)
        check_port!(port)
        { query:, plan:, server:, **(port ? { port: } : {}) }
      end

      def check_port!(port)
        return if port.nil? || Protocol::Port.valid?(port)

        raise UsageError, "--port must be a whole number from 1 to 65535"
      end

      def check_remote_path!(option, path)
        return unless laptop_home_path?(path)

        raise UsageError, "#{option} looks like a path on this laptop; --query and --plan are paths on the " \
                          "jump server. Give a path relative to your home there, such as q/query.sql, or an " \
                          "absolute path there."
      end

      def laptop_home_path?(path)
        return false unless Pathname.new(path).absolute?

        home_path = Pathname.new(@home).cleanpath
        path = Pathname.new(path).cleanpath
        path == home_path || path.to_s.start_with?("#{home_path}/")
      end

      def jump_command
        config = DriverConfig.read(@home) or raise Error, "no_driver_config"
        config["jump_command"]
      rescue DriverConfig::Bad => e
        raise Error, e.message
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
