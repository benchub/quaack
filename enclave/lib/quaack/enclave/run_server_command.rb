# frozen_string_literal: true

require "shellwords"
require_relative "cli/input"
require_relative "run_server"
require_relative "shell_command"

module Quaack
  module Enclave
    # The operator's run_server_command and destroy_command from the quaacks
    # config (DESIGN.md's run-server and "Run teardown"), run by ShellCommand. In
    # each, every {server} becomes the run's production server name and
    # every {run} the run ID, each as one shell word.
    #
    # run_server_command builds or finds the run server and prints one JSON
    # object with exactly the keys host, port, racetrack_db, and arena_db.
    # The port may be a whole number or a string of digits. The values are
    # checked as RunServer.record checks the flags. destroy_command destroys
    # the run server, and what it prints is ignored. It must be idempotent,
    # since a failed teardown keeps the store so teardown can run again.
    #
    # Errors are RunServer::Error, naming only their rule.
    module RunServerCommand
      # Seconds. Building a server from a production snapshot can be slow.
      TIMEOUT = 3600
      MAX_OUTPUT = 4096
      KEYS = %w[host port racetrack_db arena_db].freeze
      # The step's flags, by the key each overrides.
      FLAGS = { "host" => "host", "port" => "port", "racetrack_db" => "racetrack-db", "arena_db" => "arena-db" }.freeze

      module_function

      # The run server entry, as RunServer.record gives it. overrides holds
      # the step's flags by their names, such as "racetrack-db", and each
      # replaces the command's value.
      def entry(template, server:, run:, overrides: {}, timeout: TIMEOUT)
        text = run_command(template, server:, run:, timeout:, prefix: "run_server_command")
        values = parse(text).merge(FLAGS.filter_map { |key, flag| [key, overrides[flag]] if overrides.key?(flag) }.to_h)
        RunServer.record(host: values["host"], port: values["port"], racetrack_db: values["racetrack_db"],
                         arena_db: values["arena_db"])
      end

      def destroy(template, server:, run:, timeout: TIMEOUT)
        run_command(template, server:, run:, timeout:, prefix: "destroy_command")
        nil
      end

      def run_command(template, server:, run:, timeout:, prefix:)
        command = template.gsub(/\{(server|run)\}/) do
          Shellwords.escape(::Regexp.last_match(1) == "run" ? run : server)
        end
        ShellCommand.output(command, timeout:, max_output: MAX_OUTPUT, error: RunServer::Error, prefix:)
      end

      def parse(text)
        object = CLI::Input.parse_document(text)
        bad! unless object.instance_of?(Hash) && object.keys.sort == KEYS.sort

        port = object["port"]
        object.merge("port" => port.instance_of?(Integer) ? port.to_s : port)
      rescue CLI::Refused
        bad!
      end

      def bad! = raise(RunServer::Error, "run_server_command_bad_output", cause: nil)

      private_class_method :run_command, :parse, :bad!
    end
  end
end
