# frozen_string_literal: true

require_relative "version"

module Quaack
  module Driver
    # The quaack command line, run by an engineer on their laptop.
    class CLI
      USAGE = "Usage: quaack --version\n       " \
              "quaack start --server <name> --query <file> --plan <file>\n       " \
              "quaack deploy --host <jump server>\n       " \
              "quaack run --run <ID> [--rewrites <file>] [--out <path>] [--keep]\n"
      EX_USAGE = 64
      START_OPTIONS = %w[--server --query --plan].freeze
      RUN_OPTIONAL = %w[--rewrites --out].freeze
      # What run loads, only once it runs.
      RUN_FILES = %w[burndown driver_config enclave_error enclave_version llm operator_candidates pipeline runs
                     teardown transport/ssh].freeze

      # transport builds the transport to a jump host, and client the LLM
      # client from its LLM::Settings. Specs pass fakes for both, since
      # they're the edges.
      def initialize(stdout: $stdout, stderr: $stderr, home: Dir.home, transport: nil, client: nil)
        @stdout = stdout
        @stderr = stderr
        @home = home
        @transport = transport || ->(host) { Transport::Ssh.new(host:) }
        @client = client || ->(settings) { CLI.build_client(settings) }
      end

      # The LLM client run uses by default, built from settings. transport
      # is the client's edge, which a spec fakes; nil calls the real API.
      def self.build_client(settings, transport: nil)
        LLM::Client.new(burndown: Burndown.new, settings:, transport:)
      end

      def run(argv)
        if argv == ["--version"]
          @stdout.print "quaack #{VERSION}\n"
          0
        else
          subcommand(argv) || (@stderr.print(USAGE) || EX_USAGE)
        end
      end

      private

      # The exit status of a well-formed start, run, or deploy, or nil.
      def subcommand(argv)
        case argv.first
        when "start" then (options = start_options(argv.drop(1))) && start(options)
        when "run" then (options = run_options(argv.drop(1))) && run_command(**options)
        when "deploy" then deploy(argv.drop(1))
        end
      end

      # The start options as a Hash, or nil unless argv is each of them
      # exactly once, with a value.
      def start_options(argv)
        return unless argv.size == 2 * START_OPTIONS.size

        pairs = argv.each_slice(2).to_a
        return unless pairs.map(&:first).sort == START_OPTIONS.sort

        pairs.to_h { |name, value| [name.delete_prefix("--").to_sym, value] }
      end

      # Prints the run ID, or only the rule of a failure: the enclave's
      # errors already went through its egress.
      def start(options)
        require_relative "start"
        @stdout.print "#{Start.new.call(**options)}\n"
        0
      rescue Start::Error, EnclaveError, EnclaveVersion::Mismatch => e
        @stderr.print "quaack start failed: #{e.is_a?(EnclaveError) ? e.rule_with_note : e.message}\n"
        1
      end

      # The exit status of `deploy --host <host>`, or nil for other options.
      def deploy(argv)
        require_relative "deploy"
        Deploy.main(argv, stdout: @stdout, stderr: @stderr)
      end

      # { run:, rewrites:, out:, keep: } from `--run ID [--rewrites <file>]
      # [--out <path>] [--keep]`, the optional ones in any order, or nil. out
      # defaults to ./quaack-<run>.html.
      def run_options(argv)
        keep = argv.count("--keep")
        argv -= ["--keep"]
        return unless keep <= 1 && argv.size.even? && argv[0] == "--run"

        options = optional(argv.drop(2)) or return
        { run: argv[1], rewrites: options["--rewrites"], out: options["--out"] || "./quaack-#{argv[1]}.html",
          keep: keep == 1 }
      end

      # The optional run options as a Hash, or nil if one repeats or is unknown.
      def optional(argv)
        pairs = argv.each_slice(2).to_a
        pairs.to_h if pairs.map(&:first).uniq.size == pairs.size && pairs.all? { RUN_OPTIONAL.include?(it.first) }
      end

      # DESIGN.md step 5 onward, with step 7 after 6a if there's a rewrites
      # file, then prints the run ID and done. The file is read and the LLM
      # client built first, from the llm block of ~/.quaack/driver.json, so a
      # bad file, a bad block, or missing credentials fail before the jump
      # server is touched. A bad block is a usage error naming the key. A
      # failure prints only its rule, as for start.
      def run_command(run:, rewrites:, out:, keep:)
        require_run
        host = Runs.new(@home).host(run) or return usage_error("unknown run ID")
        sqls, client = prepare(rewrites) || (return usage_error(@problem))

        transport = @transport.call(host)
        EnclaveVersion.check!(transport, host)
        drive(transport, client, run, sqls, { out:, keep: })
      rescue EnclaveError, LLM::Error, OperatorCandidates::Error, EnclaveVersion::Mismatch => e
        @stderr.print "quaack run failed: #{e.respond_to?(:rule) ? e.rule : e.message}\n"
        1
      end

      # The rewrites file's SQL (nil without one) and the LLM client, or nil
      # with @problem set for a usage error.
      def prepare(rewrites)
        sqls = read_rewrites(rewrites) if rewrites
        return if rewrites && !sqls

        [sqls, @client.call(LLM.settings(DriverConfig.read(@home)&.fetch("llm", nil)))]
      rescue DriverConfig::Bad, LLM::ConfigError => e
        @problem = e.message
        nil
      end

      # Prints the report's path, if the pipeline wrote one, before done. The
      # run is torn down when the pipeline ends, however it ends, unless keep.
      def drive(transport, client, run_id, sqls, options)
        path = Teardown.around(transport:, run_id:, stderr: @stderr, keep: options[:keep]) do
          Pipeline.new(transport:, client:, run_id:, rewrites: sqls, out: options[:out]).run
        end
        @stdout.print "#{path}\n" if path
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
