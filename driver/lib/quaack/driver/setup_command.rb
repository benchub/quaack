# frozen_string_literal: true

require_relative "quiet_stream"

module Quaack
  module Driver
    # `quaack setup --run <ID>`, with the run-server flags in any order
    # after it: DESIGN.md setup (Setup), each skipped when the store
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

      # transport builds the transport to a jump host, as for CLI. Its
      # output on stdout and stderr is only for show, as run's is: once a
      # write to either fails, such as to a closed pipe, the rest there are
      # skipped, its failure message included, and setup goes on to its own
      # exit status (QuietStream).
      def initialize(home, transport, stdout, stderr)
        @home = home
        @transport = transport
        @stdout = QuietStream.wrap(stdout)
        @stderr = QuietStream.wrap(stderr)
      end

      # The exit status, or nil if argv isn't well formed.
      def call(argv)
        return unless argv.size.even? && argv[0] == "--run"

        options = self.class.optional(argv.drop(2), OPTIONS) or return
        setup(argv[1], self.class.server(options))
      end

      private

      def setup(run_id, server)
        host = Runs.new(@home).host(run_id) or return usage_error("unknown run ID")
        transport = checked(host) or return CLI::EX_USAGE
        Setup.run(transport:, run_id:, entries: Pipeline.status(transport, run_id), server:,
                  progress: Progress.new(io: @stderr, total: Setup::STEPS.size))
        @stdout.print "#{run_id} set up\n"
        0
      rescue EnclaveError, EnclaveVersion::Mismatch => e
        @stderr.print "quaack setup failed: #{EnclaveError.shown(e, resume(run_id), **Runs.new(@home).where(run_id))}\n"
        1
      end

      # A transport to host, once its quaacks is this driver's version, or
      # nil when the driver config is Bad.
      def checked(host)
        timeout = enclave_timeout or return
        @transport.call(host, timeout:).tap { EnclaveVersion.check!(it, host) }
      end

      # How long each enclave call may run: the config's
      # enclave_timeout_seconds, as for start and run, or else
      # Transport::Base::DEFAULT_TIMEOUT. nil, once it prints why, for a
      # driver config that's Bad.
      def enclave_timeout
        DriverConfig.enclave_timeout(DriverConfig.read(@home), nil, Transport::Base::DEFAULT_TIMEOUT)
      rescue DriverConfig::Bad => e
        usage_error(e.message)
        nil
      end

      def usage_error(message) = @stderr.print("quaack setup: #{message}\n") || CLI::EX_USAGE

      # What to do after ssh_failed.
      def resume(run_id) = "resume with `quaack setup --run #{run_id}`"
    end
  end
end
