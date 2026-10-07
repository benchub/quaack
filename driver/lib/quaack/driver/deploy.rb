# frozen_string_literal: true

require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "quaack/protocol/version"
require_relative "deploy_cleanup"
require_relative "deploy_diagnosis"
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
    # the gems' own dependencies, such as pg_query, from rubygems. It prints
    # a line on stdout as each step starts. If quaacks installed but won't
    # run over ssh, DeployDiagnosis works out why, and the failure says what
    # to change on the jump server. Once the check passes, it removes the
    # older versions of the two gems but the highest, with `gem uninstall
    # --user-install`, and their old gem files in ~/.quaack/deploy.
    class Deploy
      # A failure, with a message for the engineer.
      class Error < StandardError; end

      # The gems, in install order, and each one's gemspec in the checkout.
      GEMS = { "quaack-protocol" => "protocol/quaack-protocol.gemspec", "quaacks" => "enclave/quaacks.gemspec" }.freeze
      # Relative to the remote user's home, where ssh starts.
      REMOTE_DIR = DeployCleanup::REMOTE_DIR
      # The checkout this file is in, when it runs from one.
      CHECKOUT = File.expand_path("../../../..", __dir__)
      # gem install compiles pg_query, which takes a while.
      TIMEOUT = 1800
      # The most of gem install's output a failure shows.
      TAIL = 20
      # What a failed check says when DeployDiagnosis can't say more.
      GENERAL_ADVICE = "If it isn't on PATH for non-interactive ssh, put the user gem bin dir on PATH there " \
                       "(DESIGN.md, \"Deploying the enclave\")."
      # Keeps the build out of whatever bundle the driver runs in.
      UNBUNDLED = { "RUBYOPT" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil,
                    "BUNDLER_VERSION" => nil }.freeze

      # `quaack deploy --host <host>`, given the options after deploy: prints
      # each step, then what it installed, or why it failed, and returns the
      # exit status, or nil for options that aren't one --host.
      def self.main(argv, stdout:, stderr:)
        return unless argv.size == 2 && argv.first == "--host"

        host = argv.last
        stdout.print "quaack deploy: installed quaacks #{new(host:, stdout:).call} on #{host}\n"
        0
      rescue Error, ArgumentError => e
        stderr.print "quaack deploy failed: #{e.message}\n"
        1
      end

      # stdout gets a line as each step starts, or nothing if it's nil.
      # version_timeout bounds the version check, in seconds.
      def initialize(host:, ssh: "ssh", checkout: CHECKOUT, stdout: nil, version_timeout: Transport::Base::DEFAULT_TIMEOUT)
        @host = host
        @ssh = ssh
        @checkout = checkout
        @stdout = stdout
        @transport = Transport::Ssh.new(host:, ssh:, timeout: version_timeout)
      end

      # Returns the version that quaacks on the jump server now answers.
      def call
        Dir.mktmpdir("quaack-deploy") do |dir|
          files = GEMS.map { |name, gemspec| build(name, gemspec, dir) }
          files.each { copy(it) }
          install(files)
        end
        say "checking quaacks on #{@host}"
        check.tap { prune }
      end

      private

      def version(name) = name == "quaacks" ? ENCLAVE_VERSION : Protocol::VERSION

      def build(name, gemspec, dir)
        path = File.join(@checkout, gemspec)
        raise Error, "quaack deploy runs from a QUAACK checkout, and #{path} isn't there" unless File.file?(path)

        file = File.join(dir, "#{name}-#{version(name)}.gem")
        say "building #{File.basename(file)}"
        out, status = Open3.capture2e(UNBUNDLED, RbConfig.ruby, "-S", "gem", "build", File.basename(path),
                                      "--output", file, chdir: File.dirname(path))
        raise Error, "gem build #{File.basename(path)} failed:\n#{tail(out)}" unless status.success? && File.file?(file)

        file
      end

      def copy(file)
        remote = "#{REMOTE_DIR}/#{File.basename(file)}"
        say "copying #{File.basename(file)} to #{@host}"
        ssh("mkdir -p #{Shellwords.escape(REMOTE_DIR)} && cat > #{Shellwords.escape(remote)}", File.binread(file),
            "copying #{File.basename(file)}")
      end

      def install(files)
        paths = files.map { "#{REMOTE_DIR}/#{File.basename(it)}" }
        say "running gem install on #{@host}. It builds pg_query from source, which can take a few minutes."
        ssh("#{Shellwords.join(["gem", "install", "--user-install", "--no-document", *paths])} 2>&1", nil,
            "gem install")
      end

      # After the version check passed: lists what's on the jump server,
      # then prints each step DeployCleanup.steps gives and runs its
      # command, if it has one.
      def prune
        out = ssh(Shellwords.join(["ruby", "-e", DeployCleanup::LISTING]), nil, "listing old versions")
        installed = GEMS.keys.reverse.to_h { [it, version(it)] }
        DeployCleanup.steps(out, installed, host: @host).each do |line, command, what|
          say line
          ssh(command, nil, what) if command
        end
      end

      # Runs command on the jump server with stdin, and returns its stdout.
      # If it fails, raises Error, with the tail of what it printed.
      def ssh(command, stdin, what)
        argv = [@ssh, *Transport::Ssh::DEFAULT_OPTIONS, "--", @host, command]
        run = Transport::Child.run(argv, stdin:, timeout: TIMEOUT, max_output_bytes: 16 * 1024 * 1024)
        return run.stdout if run.limit.nil? && run.status.success?

        raise Error, "#{what} failed on #{@host}:\n#{tail(run.stdout)}"
      rescue Transport::Child::NotStarted
        raise Error, "couldn't run #{@ssh}", cause: nil
      end

      def check
        EnclaveVersion.check!(@transport, @host)
        ENCLAVE_VERSION
      rescue EnclaveVersion::Mismatch => e
        found = "installed quaacks #{ENCLAVE_VERSION} on #{@host}, but #{e.message.split(". ").first}."
        advice = DeployDiagnosis.new(host: @host, ssh: @ssh).call
        raise Error, advice ? "#{found}\n#{advice}" : "#{found} #{GENERAL_ADVICE}", cause: nil
      rescue EnclaveError => e
        again = e.rule_with_note(next_step: "run `quaack deploy --host #{@host}` again", timeout_hint: false)
        raise Error, "installed quaacks #{ENCLAVE_VERSION} on #{@host}, but #{again}", cause: nil
      end

      # Prints the line for a step as it starts. Each step starts a child
      # process, and Ruby flushes stdout before it spawns one, so the line
      # shows while the step runs.
      def say(line) = @stdout&.print("quaack deploy: #{line}\n")

      def tail(out) = out.to_s.lines.last(TAIL).join
    end
  end
end
