# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Quaack
  module Driver
    module Transport
      # Runs the enclave script on the jump server, as
      # `ssh [options] -- <host> quaacks <subcommand> [--name value ...]`,
      # with any input piped to ssh's stdin, which ssh passes on to quaacks.
      # Access control is ssh's own (DESIGN.md, "Where QUAACK runs").
      #
      # ssh runs locally with no shell. But ssh joins the words of the remote
      # command with spaces and hands the one string to the remote user's
      # shell, so every word is quoted with Shellwords for a POSIX shell
      # there, and the driver never builds a shell string any other way.
      # The -- ends ssh's options, so neither the host nor the command can
      # be read as one.
      #
      # ssh exits 255 when it can't connect or its session fails, and a
      # remote quaacks that dies by a signal comes back as ssh exiting 255
      # too, not as a signal, though its error line, if it printed one,
      # still decides the failure. So when a call exits 255 with nothing at
      # all on stdout, it runs a probe, `ssh [options] -- <host> true`,
      # which runs no quaacks, and keeps only its exit status. If the probe
      # fails too, the call fails as ssh_failed; otherwise, as incomplete.
      #
      # It never retries a call. A call that exits 255 with no stdout can't
      # be told from a remote quaacks killed before it printed anything,
      # and not every subcommand is safe to run twice.
      class Ssh < Base
        # -T: no terminal on the remote side, so nothing mixes into stdout.
        # BatchMode: fail rather than stop to ask for a password.
        # ServerAliveInterval and ServerAliveCountMax: a keepalive every
        # 30 seconds, so an idle firewall or NAT doesn't drop a long, quiet
        # call, and a dead link fails the call in about 2 minutes rather
        # than at the transport's timeout. ConnectTimeout: a connect that
        # can't succeed fails in 30 seconds, not TCP's minutes.
        DEFAULT_OPTIONS = ["-T", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=4",
                           "-o", "ConnectTimeout=30"].freeze

        # How long the probe may take, at most. With the default options,
        # ConnectTimeout ends it sooner.
        PROBE_TIMEOUT = 60
        # The most the probe may print before it's killed. It should print
        # nothing, and what it prints is thrown away.
        PROBE_OUTPUT_BYTES = 64 * 1024

        # A host as ssh or its config names one, such as jump-1,
        # user@jump-1.example, or 10.0.0.5. It can't start with a dash.
        HOST = /\A[A-Za-z0-9_.@:\[\]][A-Za-z0-9_.@:\[\]-]*\z/

        # host is the jump server, ssh the ssh executable, and options the
        # ssh options that come before the host, in place of
        # DEFAULT_OPTIONS. timeout and max_output_bytes are Base's. Each is
        # checked here, and a bad one raises ArgumentError.
        def initialize(host:, ssh: "ssh", options: DEFAULT_OPTIONS, **)
          super(**)
          refuse("host must be one ssh host name") unless host.is_a?(String) && HOST.match?(host)
          refuse("ssh must be the ssh executable's name or path") unless words?([ssh])
          refuse("options must be an Array of Strings") unless options.is_a?(Array) && options.all? { text?(it) }

          @host = host
          @ssh = ssh
          @options = options.dup.freeze
        end

        private

        def command(argv) = [@ssh, *@options, "--", @host, remote(argv)]

        def run(argv, stdin, on_line)
          super.tap do |run|
            next unless run.limit.nil? && run.stdout.empty? && run.status.exitstatus == 255 && !reachable?

            raise EnclaveError.new(subcommand: argv.first, rule: "ssh_failed", exit_status: 255), cause: nil
          end
        end

        # Whether ssh gets through to the host and runs true there. Only the
        # exit status counts.
        def reachable?
          Child.run([@ssh, *@options, "--", @host, "true"], stdin: nil, timeout: [@timeout, PROBE_TIMEOUT].min,
                                                            max_output_bytes: PROBE_OUTPUT_BYTES).status.success?
        rescue Child::NotStarted
          false
        end

        def remote(argv) = Shellwords.join(["quaacks", *argv])

        # Quoting can triple a value's bytes, as with a newline, so the
        # quoted remote command, one argument to ssh, is held to
        # MAX_ARGV_BYTES too, well under Linux's 128 KiB per argument.
        def argv(subcommand, args)
          super.tap do |argv|
            too_long = remote(argv).bytesize > MAX_ARGV_BYTES
            refuse("the remote command holds more than #{MAX_ARGV_BYTES} bytes") if too_long
          end
        end
      end
    end
  end
end
