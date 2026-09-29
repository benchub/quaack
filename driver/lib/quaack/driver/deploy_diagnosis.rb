# frozen_string_literal: true

require_relative "transport/child"
require_relative "transport/ssh"

module Quaack
  module Driver
    # Works out why `quaack deploy` installed quaacks but can't run it over
    # ssh, and what the engineer should change (DESIGN.md, "Deploying the
    # enclave"). It only reads: one ssh call runs PROBE, and nothing on the
    # jump server changes. The engineer makes the edit.
    #
    # The remote command is just `sh -s`, with PROBE on stdin, so even a
    # login shell that can't parse POSIX sh, such as fish or csh, runs it.
    # sh inherits the PATH that the login shell's startup files set for a
    # non-interactive ssh command, the PATH a bare `quaacks` gets.
    class DeployDiagnosis
      # Each answer is one line, "quaack-probe:<key>=<value>", so whatever
      # the login shell's startup files print around it is ignored.
      #
      # The login shell comes from getent, which asks NSS, so it covers
      # accounts in LDAP or SSSD too and isn't fooled by a startup file
      # that exports SHELL. Where getent can't answer, $SHELL, which sshd
      # sets from the same passwd entry, stands in. Whether the user gem bin
      # dir is on PATH shows in where `command -v quaacks` finds it: nowhere,
      # there (`same`), or somewhere else first. `same` compares directories
      # by their physical paths, so a symlinked PATH entry still counts.
      PROBE = <<~SH
        p=$(getent passwd "$(id -un)" 2>/dev/null); s=${p##*:}; [ -n "$s" ] || s=$SHELL
        echo "quaack-probe:shell=$s"
        if command -v ruby >/dev/null 2>&1; then
          d=$(ruby -e 'puts Gem.user_dir' 2>/dev/null)
          echo "quaack-probe:user_dir=$d"
          if [ -x "$d/bin/quaacks" ]; then echo "quaack-probe:installed=yes"; else echo "quaack-probe:installed=no"; fi
        else
          echo "quaack-probe:ruby=missing"
        fi
        if q=$(command -v quaacks 2>/dev/null); then
          echo "quaack-probe:quaacks=$q"
          a=$(cd "${q%/*}" 2>/dev/null && pwd -P); b=$(cd "$d/bin" 2>/dev/null && pwd -P)
          if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "quaack-probe:same=yes"; fi
        fi
      SH
      KEYS = %w[shell user_dir installed ruby quaacks same].freeze
      LINE = /\Aquaack-probe:(#{KEYS.join("|")})=(.*)\z/
      # A path it shows: absolute, and nothing a shell would expand.
      PLAIN_PATH = %r{\A/[A-Za-z0-9._/+-]{0,255}\z}
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
        run = Transport::Child.run(argv, stdin: PROBE, timeout: TIMEOUT, max_output_bytes: 64 * 1024)
        parse(run.stdout) if run.limit.nil? && run.status.success?
      rescue Transport::Child::NotStarted
        nil
      end

      def parse(stdout)
        stdout.lines(chomp: true).filter_map { LINE.match(it)&.captures }.to_h
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
        return if found && !PLAIN_PATH.match?(found)
        return other_quaacks(shell, found, bin) if found && facts["same"] != "yes"
        return other_ruby(shell, bin) if facts["installed"] != "yes"
        return not_on_path(shell, bin) unless found

        "quaacks is on PATH for non-interactive ssh on #{@host}, at #{found}, but it didn't answer " \
          "`quaacks version`. Run it by hand to see why."
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

      def other_ruby(shell, bin)
        "The ruby on PATH for non-interactive ssh on #{@host} uses the user gem directory " \
          "#{bin.delete_suffix("/bin")}, but quaacks isn't in #{bin}. " \
          "The gem that installed it may belong to another Ruby. " \
          "Put Ruby 3.4's bin directory first on PATH in #{file(shell)}."
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

        ". POSIX sh reads none, since $ENV is only for interactive shells, so bash or zsh may be easier"
      end

      def line(bin) = %(  export PATH="#{bin}:$PATH")
    end
  end
end
