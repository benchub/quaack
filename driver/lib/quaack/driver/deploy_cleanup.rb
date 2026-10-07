# frozen_string_literal: true

require "shellwords"

module Quaack
  module Driver
    # What Deploy removes from the jump server after the version check
    # passes (task 20260929-20): the read-only listing script it runs there,
    # the parser for what it prints, and the plan of which versions go.
    module DeployCleanup
      # Relative to the remote user's home, where ssh starts.
      REMOTE_DIR = ".quaack/deploy"
      GEM_NAMES = /quaack-protocol|quaacks/
      PLAIN_VERSION = /\d+(?:\.[0-9A-Za-z]+)*/
      LISTED_SPEC = /\Aspec:(#{GEM_NAMES})-(#{PLAIN_VERSION})\.gemspec\z/
      LISTED_FILE = /\Afile:(?:#{GEM_NAMES})-#{PLAIN_VERSION}\.gem\z/
      # Run with the remote ruby: prints the user gem dir's spec file names
      # and REMOTE_DIR's file names, one per line, each with its prefix.
      LISTING = <<~RUBY.freeze
        u = File.join(Gem.user_dir, "specifications")
        Dir.children(u).each { |f| puts "spec:" + f } if File.directory?(u)
        Dir.children(#{REMOTE_DIR.inspect}).each { |f| puts "file:" + f } if File.directory?(#{REMOTE_DIR.inspect})
      RUBY

      # What LISTING printed: each version of quaacks and quaack-protocol in
      # the user gem dir, and the names of their gem files in REMOTE_DIR.
      # Anything else, such as a line a startup file printed or a name that
      # isn't a plain version, is ignored, so whatever comes back goes into
      # a command only as a Gem::Version or a plain file name.
      def self.parse_listing(stdout)
        specs = Hash.new { |h, k| h[k] = [] }
        files = []
        stdout.each_line(chomp: true) do |line|
          if (m = LISTED_SPEC.match(line)) && Gem::Version.correct?(m[2])
            specs[m[1]] << Gem::Version.new(m[2])
          elsif LISTED_FILE.match?(line)
            files << line.delete_prefix("file:")
          end
        end
        { specs: specs.to_h, files: }
      end

      # Which of installed, a gem's versions, to remove after installing
      # new_version, and which are newer than it and stay. It keeps
      # new_version and the highest version older than it, even when the
      # operator skipped a release. Both lists are highest first.
      def self.plan(installed, new_version)
        older = installed.select { it < new_version }.sort.reverse
        { remove: older.drop(1), newer: installed.select { it > new_version }.sort.reverse }
      end

      # How each uninstall starts. `--user-install` would also remove a
      # matching version from GEM_HOME, such as an rbenv or asdf Ruby's,
      # where deploy never installs (task 20261006-22). `--install-dir`
      # touches only the dir it names, the user gem dir, which the remote
      # ruby resolves, as it does for LISTING. It's the real path, since
      # RubyGems compares the real path of --install-dir with the spec
      # dirs it finds under the path as given, so a symlinked home would
      # otherwise match nothing. It stops if ruby can't resolve that dir,
      # since gem would take an empty --install-dir as no dir at all. Each
      # step wraps it in a group with 2>&1, so ruby's stderr shows in the
      # warning too (task 20261007-2).
      UNINSTALL = %(d=$(ruby -e 'print File.realpath(Gem.user_dir)') && gem uninstall --install-dir "$d")

      # What to do after installing installed, gem name => version string,
      # in uninstall order, given what LISTING printed: [progress line,
      # command or nil, what the command is] for each step. It leaves a
      # version newer than the one installed and says so, uninstalls each
      # version plan removes from the user gem dir only, and then deletes
      # the old gem files in REMOTE_DIR. A newer version is hard to meet
      # for real: the bin/quaacks wrapper runs the highest installed
      # quaacks, so a newer one would answer the version check, which
      # fails before cleanup starts.
      def self.steps(listing, installed, host:)
        listing = parse_listing(listing)
        steps = installed.flat_map { |name, version| gem_steps(name, version, listing[:specs].fetch(name, []), host) }
        stale = listing[:files] - installed.map { |name, version| "#{name}-#{version}.gem" }
        return steps if stale.empty?

        steps << ["removing #{stale.size} old gem files from ~/#{REMOTE_DIR} on #{host}",
                  Shellwords.join(["rm", "-f", "--", *stale.map { "#{REMOTE_DIR}/#{it}" }]), "removing old gem files"]
      end

      def self.gem_steps(name, version, versions, host)
        current = Gem::Version.new(version)
        todo = plan(versions, current)
        todo[:newer].map { ["leaving #{name} #{it} on #{host}, since it's newer than #{current}", nil, nil] } +
          todo[:remove].map do |old|
            ["removing #{name} #{old} from #{host}",
             "{ #{UNINSTALL} #{Shellwords.join(["-v", old.to_s, name])}; } 2>&1",
             "gem uninstall #{name} #{old}"]
          end
      end
      private_class_method :gem_steps
    end
  end
end
