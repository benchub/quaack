# frozen_string_literal: true

require "shellwords"
require_relative "base"

module Quaack
  module Driver
    module Transport
      # Runs the enclave script on the jump server, as
      # `ssh [options] -- <host> quaacks <subcommand> [--name value ...]`,
      # with any input piped to ssh's stdin, which ssh passes on to quaacks.
      # Access control is ssh's own (README, "Where QUAACK runs").
      #
      # ssh runs locally with no shell. But ssh joins the words of the remote
      # command with spaces and hands the one string to the remote user's
      # shell, so every word is quoted with Shellwords for a POSIX shell
      # there, and the driver never builds a shell string any other way.
      # The -- ends ssh's options, so neither the host nor the command can
      # be read as one.
      #
      # ssh exits 255 when it can't connect, with nothing on stdout, so that
      # call fails as incomplete. A remote quaacks that dies by a signal
      # comes back as ssh exiting 255 too, not as a signal, but its error
      # line still decides the failure.
      class Ssh < Base
        # -T: no terminal on the remote side, so nothing mixes into stdout.
        # BatchMode: fail rather than stop to ask for a password.
        DEFAULT_OPTIONS = ["-T", "-o", "BatchMode=yes"].freeze

        # A host as ssh or its config names one, such as jump-1,
        # user@jump-1.example, or 10.0.0.5. It can't start with a dash.
        HOST = /\A[A-Za-z0-9_.@:\[\]][A-Za-z0-9_.@:\[\]-]*\z/

        # host is the jump server, ssh the ssh executable, and options the
        # ssh options that come before the host, in place of
        # DEFAULT_OPTIONS. timeout and max_output_bytes are Base's.
        def initialize(host:, ssh: "ssh", options: DEFAULT_OPTIONS, **)
          super(**)
          raise ArgumentError, "host must be one ssh host name" unless host.is_a?(String) && HOST.match?(host)
          raise ArgumentError, "options must be an Array of Strings" unless strings?(options)

          @host = host
          @ssh = ssh
          @options = options.dup.freeze
        end

        private

        def strings?(options) = options.is_a?(Array) && options.all?(String)

        def command(argv) = [@ssh, *@options, "--", @host, Shellwords.join(["quaacks", *argv])]
      end
    end
  end
end
