# frozen_string_literal: true

require "fileutils"
require "rbconfig"
require "tmpdir"
require "quaack/driver/deploy_diagnosis"

# What `quaack deploy` says when it installed quaacks but can't run it over
# ssh. ssh is faked, at the edge: the fake runs the remote command locally
# with /bin/sh, in a temp HOME that stands in for the jump server's, with a
# PATH that holds only what each example puts there. getent is a stub that
# answers the login shell, and ruby is the real one, so the probe really
# runs `ruby -e 'puts Gem.user_dir'`.
RSpec.describe Quaack::Driver::DeployDiagnosis do
  let(:dir) { Dir.mktmpdir("quaack-deploy-diagnosis") }
  let(:home) { File.join(dir, "home").tap { FileUtils.mkdir_p(it) } }
  # Gem.user_dir for this HOME with no ~/.gem, as RubyGems 3.6 gives it.
  let(:user_dir) { File.join(home, ".local", "share", "gem", "ruby", RbConfig::CONFIG["ruby_version"]) }
  let(:bin) { File.join(user_dir, "bin") }
  # The tools the probe needs besides ruby: sh, which ssh's remote command
  # runs, and id.
  let(:tools) { directory("tools", "sh" => "/bin/sh", "id" => which("id")) }
  let(:ruby_dir) { directory("ruby", "ruby" => RbConfig.ruby) }
  let(:stubs) { File.join(dir, "stubs").tap { FileUtils.mkdir_p(it) } }
  let(:check) { "Check with: ssh jump-1 quaacks --version" }

  after { FileUtils.rm_rf(dir) }

  def which(name) = ENV.fetch("PATH").split(":").map { File.join(it, name) }.find { File.executable?(it) }

  # A directory of symlinks, name => target.
  def directory(name, links)
    File.join(dir, name).tap do |path|
      FileUtils.mkdir_p(path)
      links.each { |link, target| File.symlink(target, File.join(path, link)) }
    end
  end

  def executable(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
  end

  # getent answers a passwd line with this login shell, or fails, as where
  # there's no getent.
  def login_shell(shell)
    executable(File.join(stubs, "getent"), shell ? "echo \"$2:x:1000:1000::/home/$2:#{shell}\"" : "exit 2")
  end

  def installed = executable(File.join(bin, "quaacks"), "echo quaacks")

  # Logs its arguments and stdin, then runs the remote command as sshd
  # would, with the login shell's non-interactive PATH set to path.
  def fake_ssh(path:, shell_env: "/bin/sh", remote_home: home)
    File.join(dir, "ssh").tap do |script|
      executable(script, <<~SH)
        printf '%s\\n' "$*" >> '#{dir}/ssh-args'
        while [ "$#" -gt 0 ]; do arg=$1; shift; [ "$arg" = "--" ] && break; done
        shift
        export HOME='#{remote_home}' PATH='#{path.join(":")}' SHELL='#{shell_env}'
        unset XDG_DATA_HOME GEM_HOME GEM_PATH RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION
        cd "$HOME" && exec /bin/sh -c "$*"
      SH
    end
  end

  def diagnose(path:, **)
    described_class.new(host: "jump-1", ssh: fake_ssh(path:, **)).call
  end

  it "runs one read-only probe, as `sh -s` over the driver's ssh options, and changes nothing" do
    login_shell("/bin/bash")
    installed
    before = Dir.glob("**/*", File::FNM_DOTMATCH, base: home).sort
    diagnose(path: [stubs, tools, ruby_dir])

    expect(File.read(File.join(dir, "ssh-args")))
      .to eq("-T -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=4 -o ConnectTimeout=30 " \
             "-- jump-1 sh -s\n")
    expect(Dir.glob("**/*", File::FNM_DOTMATCH, base: home).sort).to eq(before)
  end

  it "gives bash users the line for ~/.bashrc, above the early return, when the gem bin dir isn't on PATH" do
    login_shell("/bin/bash")
    installed

    expect(diagnose(path: [stubs, tools, ruby_dir])).to eq(<<~MSG.chomp)
      jump-1's login shell is bash, and #{bin}, where quaacks is, isn't on PATH for non-interactive ssh. Add this line to ~/.bashrc on jump-1, above any line that returns early for non-interactive shells:
        export PATH="#{bin}:$PATH"
      #{check}
    MSG
  end

  it "gives zsh users the same line, for ~/.zshenv" do
    login_shell("/usr/bin/zsh")
    installed

    expect(diagnose(path: [stubs, tools, ruby_dir])).to eq(<<~MSG.chomp)
      jump-1's login shell is zsh, and #{bin}, where quaacks is, isn't on PATH for non-interactive ssh. Add this line to ~/.zshenv on jump-1:
        export PATH="#{bin}:$PATH"
      #{check}
    MSG
  end

  it "tells users of another POSIX shell which file to look for" do
    login_shell("/bin/dash")
    installed

    expect(diagnose(path: [stubs, tools, ruby_dir])).to eq(<<~MSG.chomp)
      jump-1's login shell is dash, and #{bin}, where quaacks is, isn't on PATH for non-interactive ssh. Add this line to a file dash reads for non-interactive commands, if it reads one; see its manual. It may read none, so bash or zsh may be easier:
        export PATH="#{bin}:$PATH"
      #{check}
    MSG
  end

  it "falls back to $SHELL for the login shell when getent can't answer" do
    login_shell(nil)
    installed

    expect(diagnose(path: [stubs, tools, ruby_dir], shell_env: "/usr/local/bin/zsh"))
      .to start_with("jump-1's login shell is zsh,").and include("~/.zshenv")
  end

  %w[fish csh tcsh].each do |shell|
    it "says a #{shell} login shell isn't supported" do
      login_shell("/usr/bin/#{shell}")
      installed

      expect(diagnose(path: [stubs, tools, ruby_dir])).to eq(<<~MSG.chomp)
        jump-1's login shell is #{shell}, which QUAACK doesn't support. The driver needs a POSIX login shell there: bash, sh, or zsh.
        #{check}
      MSG
    end
  end

  ["/bin/ba\\033[31msh", "/bin/ba sh", "/bin/Bash"].each do |shell|
    it "gives no advice when the login shell's name isn't plain, as with #{shell.inspect}" do
      executable(File.join(stubs, "getent"), %(printf '%s:x:1000:1000::/home/%s:%b\\n' "$2" "$2" '#{shell}'))
      installed

      expect(diagnose(path: [stubs, tools, ruby_dir])).to be_nil
    end
  end

  it "says a fish login shell isn't supported even when ruby isn't on PATH either" do
    login_shell("/usr/bin/fish")
    installed

    expect(diagnose(path: [stubs, tools])).to start_with("jump-1's login shell is fish, which QUAACK doesn't support.")
  end

  it "says when ruby isn't on the non-interactive PATH" do
    login_shell("/bin/bash")
    installed

    expect(diagnose(path: [stubs, tools])).to eq(<<~MSG.chomp)
      `ruby` isn't on PATH for non-interactive ssh on jump-1, so quaacks can't run there either. Put Ruby 3.4's bin directory and the user gem bin directory (what `ruby -e 'puts Gem.user_dir'` prints, plus /bin) on PATH in ~/.bashrc on jump-1, above any line that returns early for non-interactive shells.
      #{check}
    MSG
  end

  it "says when another quaacks comes first on PATH" do
    login_shell("/bin/bash")
    installed
    other = File.join(dir, "other")
    executable(File.join(other, "quaacks"), "echo other")

    expect(diagnose(path: [stubs, tools, ruby_dir, other, bin])).to eq(<<~MSG.chomp)
      The quaacks on PATH for non-interactive ssh on jump-1 is #{other}/quaacks, not the one just installed in #{bin}. It may belong to another Ruby or gem directory. Remove it, or put this line in ~/.bashrc on jump-1, above any line that returns early for non-interactive shells:
        export PATH="#{bin}:$PATH"
      #{check}
    MSG
  end

  it "counts the installed quaacks reached through a symlinked PATH entry as the one just installed" do
    login_shell("/bin/bash")
    installed
    File.symlink(bin, File.join(dir, "linked"))

    expect(diagnose(path: [stubs, tools, ruby_dir, File.join(dir, "linked")]))
      .to start_with("quaacks is on PATH for non-interactive ssh on jump-1")
  end

  it "counts the installed quaacks as the one just installed when HOME is a symlink and PATH has the real bin" do
    login_shell("/bin/bash")
    installed
    linked_home = File.join(dir, "linked-home")
    File.symlink(home, linked_home)

    expect(diagnose(path: [stubs, tools, ruby_dir, File.realpath(bin)], remote_home: linked_home))
      .to start_with("quaacks is on PATH for non-interactive ssh on jump-1")
  end

  it "says quaacks isn't installed for this Ruby when another quaacks is on PATH" do
    login_shell("/bin/bash")
    other = File.join(dir, "other")
    executable(File.join(other, "quaacks"), "echo other")

    expect(diagnose(path: [stubs, tools, ruby_dir, other])).to eq(<<~MSG.chomp)
      quaacks isn't installed for the ruby on PATH for non-interactive ssh on jump-1: it isn't in #{bin}, that Ruby's user gem bin directory. Run `quaack deploy` to install it there. The quaacks on PATH there, #{other}/quaacks, is another one, which may belong to another Ruby or gem directory.
      #{check}
    MSG
  end

  it "says where gem install put quaacks when it's not installed for this Ruby and the gem on PATH isn't beside it" do
    login_shell("/bin/bash")
    other = File.join(dir, "other")
    executable(File.join(other, "quaacks"), "echo other")
    other_ruby = File.join(dir, "other-ruby")
    executable(File.join(other_ruby, "gem"), "echo gem")

    expect(diagnose(path: [stubs, tools, other_ruby, ruby_dir, other])).to eq(<<~MSG.chomp)
      quaacks isn't installed for the ruby on PATH for non-interactive ssh on jump-1: it isn't in #{bin}, that Ruby's user gem bin directory. The gem on PATH there, #{other_ruby}/gem, isn't beside that ruby, #{ruby_dir}/ruby, so gem install put quaacks in the user gem directory of the Ruby that gem belongs to, and this Ruby doesn't load gems from there. Put Ruby 3.4's bin directory first on PATH in ~/.bashrc on jump-1, above any line that returns early for non-interactive shells. The quaacks on PATH there, #{other}/quaacks, is another one, which may belong to another Ruby or gem directory.
      #{check}
    MSG
  end

  it "says to run `quaack deploy` when quaacks isn't installed for this Ruby and the gem on PATH is beside it" do
    login_shell("/bin/bash")
    other = File.join(dir, "other")
    executable(File.join(other, "quaacks"), "echo other")
    executable(File.join(ruby_dir, "gem"), "echo gem")

    expect(diagnose(path: [stubs, tools, ruby_dir, other]))
      .to start_with("quaacks isn't installed for the ruby on PATH for non-interactive ssh on jump-1: it isn't in " \
                     "#{bin}, that Ruby's user gem bin directory. Run `quaack deploy` to install it there.")
  end

  it "says to run `quaack deploy` when quaacks isn't installed for this Ruby and the gem's path isn't plain" do
    login_shell("/bin/bash")
    other = File.join(dir, "other")
    executable(File.join(other, "quaacks"), "echo other")
    other_ruby = File.join(dir, "other$ruby")
    executable(File.join(other_ruby, "gem"), "echo gem")

    expect(diagnose(path: [stubs, tools, other_ruby, ruby_dir, other]))
      .to start_with("quaacks isn't installed for the ruby on PATH for non-interactive ssh on jump-1: it isn't in " \
                     "#{bin}, that Ruby's user gem bin directory. Run `quaack deploy` to install it there.")
  end

  it "says when the ruby on PATH isn't the one whose gem installed quaacks" do
    login_shell("/bin/bash")
    executable(File.join(bin, "rake"), "echo rake")
    executable(File.join(ruby_dir, "gem"), "echo gem")

    expect(diagnose(path: [stubs, tools, ruby_dir])).to eq(<<~MSG.chomp)
      The ruby on PATH for non-interactive ssh on jump-1 uses the user gem directory #{user_dir}, but quaacks isn't in #{bin}. The gem that installed it may belong to another Ruby. Put Ruby 3.4's bin directory first on PATH in ~/.bashrc on jump-1, above any line that returns early for non-interactive shells.
      #{check}
    MSG
  end

  it "says when the gem on PATH isn't beside the ruby on PATH" do
    login_shell("/bin/bash")
    other_ruby = File.join(dir, "other-ruby")
    executable(File.join(other_ruby, "gem"), "echo gem")

    expect(diagnose(path: [stubs, tools, other_ruby, ruby_dir])).to eq(<<~MSG.chomp)
      The ruby on PATH for non-interactive ssh on jump-1 uses the user gem directory #{user_dir}, but quaacks isn't in #{bin}. The gem on PATH there, #{other_ruby}/gem, isn't beside that ruby, #{ruby_dir}/ruby, so gem install may have used another Ruby. Put Ruby 3.4's bin directory first on PATH in ~/.bashrc on jump-1, above any line that returns early for non-interactive shells.
      #{check}
    MSG
  end

  ["other$ruby", "other\e[31mruby"].each do |name|
    it "doesn't name the gem and ruby on PATH when the gem's path isn't plain, as with #{name.inspect}" do
      login_shell("/bin/bash")
      other_ruby = File.join(dir, name)
      executable(File.join(other_ruby, "gem"), "echo gem")

      expect(diagnose(path: [stubs, tools, other_ruby, ruby_dir])).to eq(<<~MSG.chomp)
        The ruby on PATH for non-interactive ssh on jump-1 uses the user gem directory #{user_dir}, but quaacks isn't in #{bin}. The gem that installed it may belong to another Ruby. Put Ruby 3.4's bin directory first on PATH in ~/.bashrc on jump-1, above any line that returns early for non-interactive shells.
        #{check}
      MSG
    end
  end

  # A plain `cd` resolves "link/.." in the text, to "dir", but the kernel
  # follows link first, so the gem's PATH entry is really elsewhere/ruby.
  it "compares the gem's and ruby's directories by their physical paths" do
    login_shell("/bin/bash")
    FileUtils.mkdir_p(File.join(dir, "elsewhere", "sub"))
    File.symlink(File.join(dir, "elsewhere", "sub"), File.join(dir, "link"))
    executable(File.join(dir, "elsewhere", "ruby", "gem"), "echo gem")
    gem_entry = File.join(dir, "link", "..", "ruby")

    expect(diagnose(path: [stubs, tools, gem_entry, ruby_dir])).to include(
      "The gem on PATH there, #{gem_entry}/gem, isn't beside that ruby, #{ruby_dir}/ruby,"
    )
  end

  # As above: "link/../bin" reads as the user gem bin dir, but is really
  # elsewhere/bin.
  it "compares the quaacks on PATH with the user gem bin dir by their physical paths" do
    login_shell("/bin/bash")
    installed
    FileUtils.mkdir_p(File.join(dir, "elsewhere", "sub"))
    File.symlink(File.join(dir, "elsewhere", "sub"), File.join(user_dir, "link"))
    executable(File.join(dir, "elsewhere", "bin", "quaacks"), "echo other")
    entry = File.join(user_dir, "link", "..", "bin")

    expect(diagnose(path: [stubs, tools, ruby_dir, entry])).to start_with(
      "The quaacks on PATH for non-interactive ssh on jump-1 is #{entry}/quaacks, not the one just installed"
    )
  end

  it "gives the line for a user gem dir whose path has a space" do
    login_shell("/bin/bash")
    spaced = File.join(dir, "my home")
    spaced_bin = File.join(spaced, ".local", "share", "gem", "ruby", RbConfig::CONFIG["ruby_version"], "bin")
    executable(File.join(spaced_bin, "quaacks"), "echo quaacks")

    expect(diagnose(path: [stubs, tools, ruby_dir], remote_home: spaced)).to eq(<<~MSG.chomp)
      jump-1's login shell is bash, and #{spaced_bin}, where quaacks is, isn't on PATH for non-interactive ssh. Add this line to ~/.bashrc on jump-1, above any line that returns early for non-interactive shells:
        export PATH="#{spaced_bin}:$PATH"
      #{check}
    MSG
  end

  it "says to run quaacks by hand when it's on PATH and is the one installed, but didn't answer" do
    login_shell("/bin/bash")
    installed

    expect(diagnose(path: [stubs, tools, ruby_dir, bin])).to eq(<<~MSG.chomp)
      quaacks is on PATH for non-interactive ssh on jump-1, at #{bin}/quaacks, but `quaacks version` didn't answer with version #{Quaack::Driver::ENCLAVE_VERSION}. Run it by hand to see why.
      #{check}
    MSG
  end

  it "ignores what the login shell's startup files print around the probe's answers" do
    login_shell("/bin/bash")
    installed
    File.write(File.join(dir, "noise"), "echo 'Welcome to jump-1'\necho 'quaacks=/opt/quaacks'\n")
    ssh = fake_ssh(path: [stubs, tools, ruby_dir])
    File.write(ssh, File.read(ssh).sub("cd \"$HOME\"", ". '#{dir}/noise'\ncd \"$HOME\""))

    expect(described_class.new(host: "jump-1", ssh:).call).to start_with("jump-1's login shell is bash, and #{bin},")
  end

  it "ignores an answer a startup file prints in the middle of a line" do
    login_shell("/bin/bash")
    installed
    File.write(File.join(dir, "noise"), "echo 'motd quaack-probe:ruby=missing'\n")
    ssh = fake_ssh(path: [stubs, tools, ruby_dir])
    File.write(ssh, File.read(ssh).sub("cd \"$HOME\"", ". '#{dir}/noise'\ncd \"$HOME\""))

    expect(described_class.new(host: "jump-1", ssh:).call).to start_with("jump-1's login shell is bash, and #{bin},")
  end

  it "gives no advice when the quaacks it finds isn't at a plain path" do
    login_shell("/bin/bash")
    installed
    other = File.join(dir, "other$dir")
    executable(File.join(other, "quaacks"), "echo other")

    expect(diagnose(path: [stubs, tools, ruby_dir, other])).to be_nil
  end

  it "gives no advice when the probe fails, so deploy keeps its general message" do
    executable(File.join(dir, "ssh"), "cat >/dev/null\necho quaack-probe:shell=/usr/bin/fish\nexit 255")

    expect(described_class.new(host: "jump-1", ssh: File.join(dir, "ssh")).call).to be_nil
  end

  it "gives no advice when a path it would show isn't a plain path" do
    login_shell("/bin/bash")
    executable(File.join(stubs, "ruby"), "echo '/home/a/$(reboot)/gem'")

    expect(diagnose(path: [stubs, tools])).to be_nil
  end

  it "gives no advice when ssh can't be run" do
    expect(described_class.new(host: "jump-1", ssh: File.join(dir, "no-such-ssh")).call).to be_nil
  end
end
