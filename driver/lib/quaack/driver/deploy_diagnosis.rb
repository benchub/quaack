# frozen_string_literal: true

require_relative "deploy_probe"
require_relative "transport/child"
require_relative "transport/ssh"
require_relative "version"

module Quaack
  module Driver
    # Works out why `quaack deploy` installed quaacks but can't run it over
    # ssh, and what the engineer should change (DESIGN.md, "Deploying the
    # enclave"). It only reads: one ssh call runs DeployProbe::SCRIPT, and
    # nothing on the jump server changes. The engineer makes the edit.
    #
    # The remote command is just `sh -s`, with the script on stdin, so even a
    # login shell that can't parse POSIX sh, such as fish or csh, runs it.
    # sh inherits the PATH that the login shell's startup files set for a
    # non-interactive ssh command, the PATH a bare `quaacks` gets.
    class DeployDiagnosis
      # A path it shows: absolute, and nothing a shell would expand inside
      # double quotes. Spaces are fine there.
      PLAIN_PATH = %r{\A/[A-Za-z0-9._/+ -]{0,255}\z}
      SHELL_NAME = /\A[a-z0-9]{1,16}\z/
      UNSUPPORTED = %w[fish csh tcsh].freeze
      EARLY_RETURN = "above any line that returns early for non-interactive shells"
      TIMEOUT = 60

      def initialize(host:, ssh: "ssh")
        @host = host
        @ssh = ssh
      end

      # The advice, ending with the command to check it, or nil if the
      # probe failed or found something it can't show.
      def call
        facts = probe or return
        advice = advise(facts) or return
        "#{advice}\nCheck with: ssh #{@host} quaacks --version"
      end

      private

      def probe
        argv = [@ssh, *Transport::Ssh::DEFAULT_OPTIONS, "--", @host, "sh -s"]
        run = Transport::Child.run(argv, stdin: DeployProbe::SCRIPT, timeout: TIMEOUT, max_output_bytes: 64 * 1024)
        DeployProbe.parse(run.stdout) if run.limit.nil? && run.status.success?
      rescue Transport::Child::NotStarted
        nil
      end

      def advise(facts)
        shell = facts["shell"].to_s.split("/").last.to_s
        return unless SHELL_NAME.match?(shell)
        return unsupported(shell) if UNSUPPORTED.include?(shell)
        return missing_ruby(shell) if facts["ruby"] == "missing"

        dir = facts["user_dir"]
        return unless PLAIN_PATH.match?(dir.to_s)

        installed_advice(facts, shell, "#{dir}/bin")
      end

      def installed_advice(facts, shell, bin)
        found = facts["quaacks"]
        return not_found(facts, shell, bin) unless found
        return unless PLAIN_PATH.match?(found)
        return not_installed(facts, shell, found, bin) if facts["installed"] != "yes"
        return other_quaacks(shell, found, bin) if facts["same"] != "yes"

        "quaacks is on PATH for non-interactive ssh on #{@host}, at #{found}, but `quaacks version` didn't answer " \
          "with version #{ENCLAVE_VERSION}. Run it by hand to see why."
      end

      def not_found(facts, shell, bin)
        facts["installed"] == "yes" ? not_on_path(shell, bin) : other_ruby(facts, shell, bin)
      end

      def unsupported(shell)
        "#{@host}'s login shell is #{shell}, which QUAACK doesn't support. " \
          "The driver needs a POSIX login shell there: bash, sh, or zsh."
      end

      def missing_ruby(shell)
        "`ruby` isn't on PATH for non-interactive ssh on #{@host}, so quaacks can't run there either. " \
          "Put Ruby 3.4's bin directory and the user gem bin directory (what `ruby -e 'puts Gem.user_dir'` " \
          "prints, plus /bin) on PATH in #{file(shell)}."
      end

      def other_quaacks(shell, found, bin)
        "The quaacks on PATH for non-interactive ssh on #{@host} is #{found}, not the one just installed in " \
          "#{bin}. It may belong to another Ruby or gem directory. Remove it, or put this line in " \
          "#{file(shell)}:\n#{line(bin)}"
      end

      def not_installed(facts, shell, found, bin)
        "quaacks isn't installed for the ruby on PATH for non-interactive ssh on #{@host}: it isn't in #{bin}, " \
          "that Ruby's user gem bin directory. #{where_it_went(facts, shell)} The quaacks on PATH there, " \
          "#{found}, is another one, which may belong to another Ruby or gem directory."
      end

      def where_it_went(facts, shell)
        gem, ruby = other_gem(facts)
        return "Run `quaack deploy` to install it there." unless gem

        "The gem on PATH there, #{gem}, isn't beside that ruby, #{ruby}, so gem install put quaacks in the user " \
          "gem directory of the Ruby that gem belongs to, and this Ruby doesn't load gems from there. " \
          "Put Ruby 3.4's bin directory first on PATH in #{file(shell)}."
      end

      def other_ruby(facts, shell, bin)
        "The ruby on PATH for non-interactive ssh on #{@host} uses the user gem directory " \
          "#{bin.delete_suffix("/bin")}, but quaacks isn't in #{bin}. #{which_gem(facts)} " \
          "Put Ruby 3.4's bin directory first on PATH in #{file(shell)}."
      end

      def which_gem(facts)
        gem, ruby = other_gem(facts)
        return "The gem that installed it may belong to another Ruby." unless gem

        "The gem on PATH there, #{gem}, isn't beside that ruby, #{ruby}, so gem install may have used another Ruby."
      end

      # The gem and ruby on PATH, when they're in different directories and
      # both paths are plain; otherwise nil.
      def other_gem(facts)
        paths = facts.values_at("gem", "ruby_path")
        paths if facts["gem_dir"] != "same" && paths.all? { PLAIN_PATH.match?(it.to_s) }
      end

      def not_on_path(shell, bin)
        "#{@host}'s login shell is #{shell}, and #{bin}, where quaacks is, isn't on PATH for non-interactive ssh. " \
          "Add this line to #{file(shell)}#{other_posix(shell)}:\n#{line(bin)}"
      end

      # Where the line goes: the file each shell reads for a non-interactive
      # ssh command.
      def file(shell)
        case shell
        when "bash" then "~/.bashrc on #{@host}, #{EARLY_RETURN}"
        when "zsh" then "~/.zshenv on #{@host}"
        else "a file #{shell} reads for non-interactive commands, if it reads one; see its manual"
        end
      end

      def other_posix(shell)
        return "" if %w[bash zsh].include?(shell)

        ". It may read none, so bash or zsh may be easier"
      end

      def line(bin) = %(  export PATH="#{bin}:$PATH")
    end
  end
end
