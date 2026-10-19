# frozen_string_literal: true

require_relative "quiet_stream"

module Quaack
  module Driver
    # `quaack redact-rewrite --run <ID>` (DESIGN.md's redact-rewrite): an
    # operator's rewrite, written with the real literals, read from stdin
    # and sent over ssh to `quaacks redact-rewrite`, which swaps each literal
    # for the run's placeholder. It prints the result, which holds only
    # placeholders, on stdout, so the operator can redirect it into a
    # --rewrites file.
    #
    # The statement holds production literals, so it goes only on the
    # enclave call's stdin: never on a command line, to a file, into the run
    # record, or into any message. It takes no --file or other argument
    # that could hold it. A failure prints only the enclave's rule, and for
    # a literal it can't place, the literal's position. It needs
    # CLI::RUN_FILES loaded.
    class RedactRewriteCommand
      # Far past any one statement, and within what the enclave reads.
      MAX_BYTES = 16 * 1024 * 1024
      NEXT_STEP = "fix the rewrite and run quaack redact-rewrite again"

      def initialize(home, transport, stdin, stdout, stderr)
        @home = home
        @transport = transport
        @stdin = stdin
        @stdout = QuietStream.wrap(stdout)
        @stderr = QuietStream.wrap(stderr)
      end

      # The exit status, or nil if argv isn't `--run <ID>`.
      def call(argv)
        return unless argv.size == 2 && argv[0] == "--run"

        sql = statement or return usage_error("no SQL on stdin")
        where = SetupCommand.where(@home, argv[1], @stderr, "redact-rewrite") or return CLI::EX_USAGE
        redact(argv[1], sql, where)
      end

      private

      # stdin as UTF-8 text, or nil when it's empty, too large, or not UTF-8.
      def statement
        text = @stdin.read(MAX_BYTES + 1) || +""
        text = text.dup.force_encoding(Encoding::UTF_8)
        text if !text.strip.empty? && text.bytesize <= MAX_BYTES && text.valid_encoding?
      end

      def redact(run_id, sql, where)
        transport = @transport.call(where[:jump], timeout: timeout).tap { EnclaveVersion.check!(it, where[:jump]) }
        reply = transport.call("redact-rewrite", args: { run: run_id }, input: { "sql" => sql })
        found = reply.messages.find { it["type"] == "redacted_rewrite" }
        raise EnclaveError.new(subcommand: "redact-rewrite", rule: "unexpected_output"), cause: nil unless found

        @stdout.print("#{found["sql"]}\n")
        0
      rescue EnclaveError, EnclaveVersion::Mismatch, DriverConfig::Bad => e
        @stderr.print("quaack redact-rewrite failed: #{EnclaveError.shown(e, NEXT_STEP, **where)}\n")
        1
      end

      def timeout = DriverConfig.enclave_timeout(DriverConfig.read(@home), nil, Transport::Base::DEFAULT_TIMEOUT)

      def usage_error(message) = @stderr.print("quaack redact-rewrite: #{message}\n") || CLI::EX_USAGE
    end
  end
end
