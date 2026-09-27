# frozen_string_literal: true

require_relative "version"

module Quaack
  module Driver
    # The quaack command line, run by an engineer on their laptop.
    class CLI
      USAGE = "Usage: quaack --version\n       " \
              "quaack start --server <name> --query <file> --plan <file>\n       " \
              "quaack run --run <ID> [--rewrites <file>] [--out <path>] [--keep]\n"
      EX_USAGE = 64
      START_OPTIONS = %w[--server --query --plan].freeze
      RUN_OPTIONAL = %w[--rewrites --out].freeze

      # transport builds the transport to a jump host, and client the LLM
      # client. Specs pass fakes for both, since they're the edges.
      def initialize(stdout: $stdout, stderr: $stderr, home: Dir.home, transport: nil, client: nil)
        @stdout = stdout
        @stderr = stderr
        @home = home
        @transport = transport || ->(host) { Transport::Ssh.new(host:) }
        @client = client || -> { LLM::Client.new(burndown: Burndown.new) }
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

      # The exit status of a well-formed start or run, or nil.
      def subcommand(argv)
        if argv.first == "start" && (options = start_options(argv.drop(1)))
          start(options)
        elsif argv.first == "run" && (options = run_options(argv.drop(1)))
          run_command(**options)
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

      # README step 5 onward, with step 7 after 6a if there's a rewrites
      # file, then prints the run ID and done. The
      # file is read first, so a bad one fails before the jump server is
      # touched. A failure prints only its rule, as for start.
      def run_command(run:, rewrites:, out:, keep:)
        require_run
        host = Runs.new(@home).host(run) or return usage_error("unknown run ID")
        sqls = read_rewrites(rewrites) if rewrites
        return usage_error(@rewrites_problem) if rewrites && !sqls

        transport = @transport.call(host)
        EnclaveVersion.check!(transport, host)
        drive(transport, @client.call, run, sqls, { out:, keep: })
      rescue EnclaveError, LLM::Error, OperatorCandidates::Error, EnclaveVersion::Mismatch => e
        @stderr.print "quaack run failed: #{e.respond_to?(:rule) ? e.rule : e.message}\n"
        1
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

      def require_run
        require_relative "burndown"
        require_relative "enclave_error"
        require_relative "enclave_version"
        require_relative "llm"
        require_relative "operator_candidates"
        require_relative "pipeline"
        require_relative "runs"
        require_relative "teardown"
        require_relative "transport/ssh"
      end

      def read_rewrites(path)
        OperatorCandidates.from_file(path)
      rescue SystemCallError, IOError
        @rewrites_problem = "can't read the rewrites file"
        nil
      rescue OperatorCandidates::Error => e
        @rewrites_problem = e.message
        nil
      end

      def usage_error(message)
        @stderr.print "quaack run: #{message}\n"
        EX_USAGE
      end
    end
  end
end
