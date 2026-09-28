# frozen_string_literal: true

require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "quaack/protocol/version"
require_relative "enclave_version"
require_relative "transport/child"
require_relative "transport/ssh"
require_relative "version"

module Quaack
  module Driver
    # `quaack deploy --host <jump server>` (DESIGN.md, "Deploying the enclave").
    # It builds the quaack-protocol and quaacks gems from this checkout's
    # gemspecs, in child processes, so the driver never loads the enclave. It
    # copies them over ssh into ~/.quaack/deploy on the jump server, runs
    # `gem install --user-install` there, never sudo, and then checks that
    # `quaacks version` over ssh answers ENCLAVE_VERSION. gem install gets
    # the gems' own dependencies, such as pg_query, from rubygems.
    class Deploy
      # A failure, with a message for the engineer.
      class Error < StandardError; end

      # The gems, in install order, and each one's gemspec in the checkout.
      GEMS = { "quaack-protocol" => "protocol/quaack-protocol.gemspec", "quaacks" => "enclave/quaacks.gemspec" }.freeze
      # Relative to the remote user's home, where ssh starts.
      REMOTE_DIR = ".quaack/deploy"
      # The checkout this file is in, when it runs from one.
      CHECKOUT = File.expand_path("../../../..", __dir__)
      # gem install compiles pg_query, which takes a while.
      TIMEOUT = 1800
      # The most of gem install's output a failure shows.
      TAIL = 20
      # Keeps the build out of whatever bundle the driver runs in.
      UNBUNDLED = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil }.freeze

      # `quaack deploy --host <host>`, given the options after deploy: prints
      # what it installed, or why it failed, and returns the exit status, or
      # nil for options that aren't one --host.
      def self.main(argv, stdout:, stderr:)
        return unless argv.size == 2 && argv.first == "--host"

        host = argv.last
        stdout.print "quaack deploy: installed quaacks #{new(host:).call} on #{host}\n"
        0
      rescue Error, ArgumentError => e
        stderr.print "quaack deploy failed: #{e.message}\n"
        1
      end

      def initialize(host:, ssh: "ssh", checkout: CHECKOUT)
        @host = host
        @ssh = ssh
        @checkout = checkout
        @transport = Transport::Ssh.new(host:, ssh:)
      end

      # Returns the version that quaacks on the jump server now answers.
      def call
        Dir.mktmpdir("quaack-deploy") do |dir|
          files = GEMS.map { |name, gemspec| build(name, gemspec, dir) }
          files.each { copy(it) }
          install(files)
        end
        check
      end

      private

      def version(name) = name == "quaacks" ? ENCLAVE_VERSION : Protocol::VERSION

      def build(name, gemspec, dir)
        path = File.join(@checkout, gemspec)
        raise Error, "quaack deploy runs from a QUAACK checkout, and #{path} isn't there" unless File.file?(path)

        file = File.join(dir, "#{name}-#{version(name)}.gem")
        out, status = Open3.capture2e(UNBUNDLED, RbConfig.ruby, "-S", "gem", "build", File.basename(path),
                                      "--output", file, chdir: File.dirname(path))
        raise Error, "gem build #{File.basename(path)} failed:\n#{tail(out)}" unless status.success? && File.file?(file)

        file
      end

      def copy(file)
        remote = "#{REMOTE_DIR}/#{File.basename(file)}"
        ssh("mkdir -p #{Shellwords.escape(REMOTE_DIR)} && cat > #{Shellwords.escape(remote)}", File.binread(file),
            "copying #{File.basename(file)}")
      end

      def install(files)
        paths = files.map { "#{REMOTE_DIR}/#{File.basename(it)}" }
        ssh("#{Shellwords.join(["gem", "install", "--user-install", "--no-document", *paths])} 2>&1", nil,
            "gem install")
      end

      # Runs command on the jump server with stdin, and raises Error, with
      # the tail of what it printed, if it fails.
      def ssh(command, stdin, what)
        argv = [@ssh, *Transport::Ssh::DEFAULT_OPTIONS, "--", @host, command]
        run = Transport::Child.run(argv, stdin:, timeout: TIMEOUT, max_output_bytes: 16 * 1024 * 1024)
        return if run.limit.nil? && run.status.success?

        raise Error, "#{what} failed on #{@host}:\n#{tail(run.stdout)}"
      rescue Transport::Child::NotStarted
        raise Error, "couldn't run #{@ssh}", cause: nil
      end

      def check
        EnclaveVersion.check!(@transport, @host)
        ENCLAVE_VERSION
      rescue EnclaveVersion::Mismatch => e
        raise Error, "installed quaacks #{ENCLAVE_VERSION} on #{@host}, but #{e.message.split(". ").first}. " \
                     "If it isn't on PATH for non-interactive ssh, put the user gem bin dir on PATH there " \
                     "(DESIGN.md, \"Deploying the enclave\").", cause: nil
      end

      def tail(out) = out.to_s.lines.last(TAIL).join
    end
  end
end
