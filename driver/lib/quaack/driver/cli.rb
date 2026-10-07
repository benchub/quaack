# frozen_string_literal: true

require_relative "arguments"
require_relative "quiet_stream"
require_relative "version"
require_relative "setup_command"

module Quaack
  module Driver
    # The quaack command line, run by an engineer on their laptop.
    class CLI
      USAGE = "Usage: quaack --version\n       " \
              "quaack start --server <name> --query <file> --plan <file> [--port <n>] [--captured-at <time>]\n       " \
              "quaack deploy --host <jump server>\n       " \
              "quaack setup --run <ID> #{SetupCommand::USAGE}\n       " \
              "quaack run --run <ID> [--rewrites <file>] [--out <path>] [--keep] [--enclave-timeout-seconds <n>] " \
              "#{SetupCommand::USAGE}\n".freeze
      EX_USAGE = 64
      START_OPTIONS = %w[--server --query --plan].freeze
      START_OPTIONAL = %w[--port --captured-at].freeze
      RUN_OPTIONAL = (%w[--rewrites --out --enclave-timeout-seconds] + SetupCommand::OPTIONS).freeze
      # What setup and run load, only once they run.
      RUN_FILES = %w[burndown driver_config enclave_error enclave_version llm operator_candidates pipeline progress runs
                     setup teardown transport/ssh].freeze

      # transport builds the transport to a jump host, and client the LLM
      # client from its LLM::Settings. Specs pass fakes for both, since
      # they're the edges. run and setup pass transport the enclave call
      # timeout as timeout:.
      def initialize(stdout: $stdout, stderr: $stderr, home: Dir.home, transport: nil, client: nil)
        @stdout = stdout
        @stderr = stderr
        @home = home
        @transport = transport || ->(host, **timeout) { Transport::Ssh.new(host:, **timeout) }
        @client = client || ->(settings) { CLI.build_client(settings) }
      end

      # The LLM client run uses by default, built from settings. transport
      # is the client's edge, which a spec fakes; nil calls the real API.
      def self.build_client(settings, transport: nil)
        LLM::Client.new(burndown: Burndown.new, settings:, transport:)
      end

      def run(argv)
        return @stdout.print("quaack #{VERSION}\n") || 0 if argv == ["--version"]

        Arguments.not_utf8(argv, USAGE, @stderr) || subcommand(argv) || (@stderr.print(USAGE) || EX_USAGE)
      end

      private

      # The exit status of a well-formed start, setup, run, or deploy, or nil.
      def subcommand(argv)
        case argv.first
        when "start" then (options = start_options(argv.drop(1))) && start(options)
        when "setup" then setup(argv.drop(1))
        when "run" then (options = run_options(argv.drop(1))) && run_command(**options)
        when "deploy" then deploy(argv.drop(1))
        end
      end

      # The start options as a Hash, or nil unless argv is each of them
      # exactly once, with a value, and --port and --captured-at each at most
      # once, in any order. Each key is the option's name as a keyword, such
      # as captured_at.
      def start_options(argv)
        options = argv.size.even? && SetupCommand.optional(argv, START_OPTIONS + START_OPTIONAL)
        return unless options && START_OPTIONS.all? { options.key?(it) }

        options.to_h { |name, value| [name.delete_prefix("--").tr("-", "_").to_sym, value] }
      end

      # Prints the run ID, or only the rule of a failure: the enclave's
      # errors already went through its egress.
      def start(options)
        require_relative "start"
        @stdout.puts(Start.new.call(**options)) || 0
      rescue Start::Error, EnclaveError, EnclaveVersion::Mismatch => e
        return @stderr.print("quaack start: #{e.message}\n") || EX_USAGE if e.is_a?(Start::UsageError)

        @stderr.print "quaack start failed: #{EnclaveError.shown(e, "run `quaack start` again")}\n"
        1
      end

      # The exit status of `deploy --host <host>`, or nil for other options.
      def deploy(argv)
        require_relative "deploy"
        Deploy.main(argv, stdout: @stdout, stderr: @stderr)
      end

      # The exit status of a well-formed `setup`, or nil.
      def setup(argv) = require_run && SetupCommand.new(@home, @transport, @stdout, @stderr).call(argv)

      # { run:, rewrites:, out:, keep:, server:, timeout: } from `--run ID
      # [--rewrites <file>] [--out <path>] [--keep]
      # [--enclave-timeout-seconds <n>]` and the run-server flags, the
      # optional ones in any order, or nil. out defaults to
      # ./quaack-<run>.html. server holds the run-server flags given, by
      # option name without its dashes. timeout is the flag's text, or nil.
      def run_options(argv)
        keep = argv.count("--keep")
        argv -= ["--keep"]
        return unless keep <= 1 && argv.size.even? && argv[0] == "--run"

        options = SetupCommand.optional(argv.drop(2), RUN_OPTIONAL) or return
        { run: argv[1], rewrites: options["--rewrites"], out: options["--out"] || "./quaack-#{argv[1]}.html",
          keep: keep == 1, server: SetupCommand.server(options), timeout: options["--enclave-timeout-seconds"] }
      end

      # DESIGN.md setup first, as Setup, unless the store says the
      # run has had them, then index-search onward, with operator-rewrites after llm-rewrites if
      # there's a rewrites file, then prints the run ID and done. The file
      # is read and the LLM client built first, from the llm block of
      # ~/.quaack/driver.json, so a bad file, a bad block, or missing
      # credentials fail before the jump server is touched. A bad block is
      # a usage error naming the key. An LLM failure prints its whole
      # message, rule and detail, since the detail is the provider's own
      # error text. Any other failure prints only its rule, as for start.
      # What to do next says to resume the run only while its store is left
      # (Teardown.failure).
      #
      # Each enclave call may run for --enclave-timeout-seconds, or else the
      # config's enclave_timeout_seconds, or else
      # Transport::Base::DEFAULT_TIMEOUT. A flag that isn't a positive
      # number is a usage error.
      #
      # Its progress and messages on stderr are only for show: once a write
      # there fails, such as to a closed pipe, the rest are skipped and the
      # run goes on to its own exit status (QuietStream).
      def run_command(run:, rewrites:, timeout:, **options)
        require_run
        @stderr = QuietStream.wrap(@stderr)
        where = Runs.new(@home).where(run) or return usage_error("unknown run ID")
        sqls, client, timeout = prepare(rewrites, timeout) || (return usage_error(@problem))

        teardown = Teardown.new(checked(where[:jump], timeout), run, @stderr)
        drive(teardown, client, run, sqls, options)
      rescue EnclaveError, LLM::Error, OperatorCandidates::Error, EnclaveVersion::Mismatch, Teardown::DriverError => e
        @stderr.print "quaack run failed: #{Teardown.failure(e, teardown, run, **where)}\n"
        1
      end

      # A transport to the run's jump host, with timeout, once its quaacks
      # is this driver's version. A mismatch raises before run_command has
      # a Teardown, so its next step is to resume the run: nothing has run.
      def checked(jump, timeout) = @transport.call(jump, timeout:).tap { EnclaveVersion.check!(it, jump) }

      # The rewrites file's SQL (nil without one), the LLM client, and the
      # enclave call timeout (DriverConfig.enclave_timeout, from flag, the
      # --enclave-timeout-seconds text or nil), or nil with @problem set for
      # a usage error.
      def prepare(rewrites, flag)
        sqls = read_rewrites(rewrites) if rewrites
        return if rewrites && !sqls

        config = DriverConfig.read(@home)
        [sqls, @client.call(LLM.settings(config&.fetch("llm", nil))),
         DriverConfig.enclave_timeout(config, flag, Transport::Base::DEFAULT_TIMEOUT)]
      rescue DriverConfig::Bad, DriverConfig::BadFlag, LLM::ConfigError => e
        @problem = e.message
        nil
      end

      # Prints the report's path as soon as the pipeline writes it, so it
      # shows even when teardown then fails, and done after. The run is torn
      # down when the pipeline ends, however it ends, unless keep.
      def drive(teardown, client, run_id, sqls, options)
        teardown.around(keep: options[:keep]) do
          path = Pipeline.new(transport: teardown.transport, client:, run_id:, rewrites: sqls, out: options[:out],
                              stderr: @stderr, setup: options[:server]).run
          @stdout.print "#{path}\n" if path
        end
        @stdout.print "#{run_id} done\n"
        0
      end

      def require_run = RUN_FILES.each { require_relative it }

      def read_rewrites(path)
        OperatorCandidates.from_file(path)
      rescue SystemCallError, IOError, OperatorCandidates::Error => e
        @problem = e.is_a?(OperatorCandidates::Error) ? e.message : "can't read the rewrites file"
        nil
      end

      def usage_error(message) = @stderr.print("quaack run: #{message}\n") || EX_USAGE
    end
  end
end
