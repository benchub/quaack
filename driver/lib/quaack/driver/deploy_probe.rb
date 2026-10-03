# frozen_string_literal: true

module Quaack
  module Driver
    # The read-only script DeployDiagnosis runs on the jump server with
    # `sh -s`, and the parser for what it prints.
    #
    # Each answer is one line, "quaack-probe:<key>=<value>", so whatever the
    # login shell's startup files print around it is ignored.
    #
    # The login shell comes from getent, which asks NSS, so it covers
    # accounts in LDAP or SSSD too and isn't fooled by a startup file that
    # exports SHELL. Where getent can't answer, $SHELL stands in: OpenSSH's
    # sshd sets it from the same passwd entry (do_setup_env in session.c).
    # Whether the user gem bin dir is on PATH shows in where `command -v
    # quaacks` finds it: nowhere, there (`same`), or somewhere else first.
    # `same` compares directories by their physical paths, so a symlinked
    # PATH entry still counts. `gem_dir` does the same for the directories
    # of `gem` and `ruby`, since deploy's gem install runs whichever `gem`
    # comes first.
    module DeployProbe
      SCRIPT = <<~SH
        p=$(getent passwd "$(id -un)" 2>/dev/null); s=${p##*:}; [ -n "$s" ] || s=$SHELL
        echo "quaack-probe:shell=$s"
        if r=$(command -v ruby 2>/dev/null); then
          echo "quaack-probe:ruby_path=$r"
          d=$(ruby -e 'puts Gem.user_dir' 2>/dev/null)
          echo "quaack-probe:user_dir=$d"
          if [ -x "$d/bin/quaacks" ]; then echo "quaack-probe:installed=yes"; else echo "quaack-probe:installed=no"; fi
          if g=$(command -v gem 2>/dev/null); then
            echo "quaack-probe:gem=$g"
            a=$(cd "${g%/*}" 2>/dev/null && pwd -P); b=$(cd "${r%/*}" 2>/dev/null && pwd -P)
            if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "quaack-probe:gem_dir=same"; fi
          fi
        else
          echo "quaack-probe:ruby=missing"
        fi
        if q=$(command -v quaacks 2>/dev/null); then
          echo "quaack-probe:quaacks=$q"
          a=$(cd "${q%/*}" 2>/dev/null && pwd -P); b=$(cd "$d/bin" 2>/dev/null && pwd -P)
          if [ -n "$a" ] && [ "$a" = "$b" ]; then echo "quaack-probe:same=yes"; fi
        fi
      SH
      KEYS = %w[shell ruby_path user_dir installed gem gem_dir ruby quaacks same].freeze
      LINE = /\Aquaack-probe:(#{KEYS.join("|")})=(.*)\z/

      # The answers in stdout, key => value.
      def self.parse(stdout)
        stdout.lines(chomp: true).filter_map { LINE.match(it)&.captures }.to_h
      end
    end
  end
end
