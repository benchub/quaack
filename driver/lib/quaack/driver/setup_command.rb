# frozen_string_literal: true

module Quaack
  module Driver
    # `quaack setup --run <ID>`, with the run-server flags in any order
    # after it: DESIGN.md steps 2 to 4a (Setup), each skipped when the store
    # says it's done, then the run ID and "set up". A failure prints only
    # its rule, as for start, and keeps the run, so setup can run again.
    # It needs CLI::RUN_FILES loaded.
    class SetupCommand
      # The run-server flags setup and run pass to `quaacks run-server`.
      OPTIONS = %w[--host --port --racetrack-db --arena-db].freeze
      USAGE = "[--host <host>] [--port <port>] [--racetrack-db <name>] [--arena-db <name>]"

      # The run-server flags in options, by name without their dashes.
      def self.server(options) = options.slice(*OPTIONS).transform_keys { it.delete_prefix("--") }

      # The options in argv, `--name value` pairs, as a Hash, or nil if one
      # repeats or isn't allowed.
      def self.optional(argv, allowed)
        pairs = argv.each_slice(2).to_a
        pairs.to_h if pairs.map(&:first).uniq.size == pairs.size && pairs.all? { allowed.include?(it.first) }
      end

      # transport builds the transport to a jump host, as for CLI.
      def initialize(home, transport, stdout, stderr)
        @home = home
        @transport = transport
        @stdout = stdout
        @stderr = stderr
      end

      # The exit status, or nil if argv isn't well formed.
      def call(argv)
        return unless argv.size.even? && argv[0] == "--run"

        options = self.class.optional(argv.drop(2), OPTIONS) or return
        setup(argv[1], self.class.server(options))
      end

      private

      def setup(run_id, server)
        host = Runs.new(@home).host(run_id) or return @stderr.print("quaack setup: unknown run ID\n") || CLI::EX_USAGE
        transport = @transport.call(host)
        EnclaveVersion.check!(transport, host)
        Setup.run(transport:, run_id:, entries: Pipeline.status(transport, run_id), server:,
                  progress: Progress.new(io: @stderr, total: Setup::STEPS.size))
        @stdout.print "#{run_id} set up\n"
        0
      rescue EnclaveError, EnclaveVersion::Mismatch => e
        @stderr.print "quaack setup failed: #{e.is_a?(EnclaveError) ? e.rule_with_note : e.message}\n"
        1
      end
    end
  end
end
