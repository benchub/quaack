# frozen_string_literal: true

require "fileutils"
require "open3"
require "stringio"
require "rbconfig"
require "tmpdir"
require "quaack/driver/deploy"

# `quaack deploy`: builds the quaacks and quaack-protocol gems here, copies
# them over ssh, and installs them into the jump server's user gem dir. ssh
# is faked, at the edge: the fake runs the remote command locally, in a temp
# HOME that stands in for the jump server's, outside this bundle. So a real
# `gem install --user-install` runs. pg_query and pg, which the jump server
# gets from rubygems, come from this repo's vendor/bundle through GEM_PATH,
# so no network is needed and nothing compiles.
RSpec.describe Quaack::Driver::Deploy do
  let(:dir) { Dir.mktmpdir("quaack-driver-deploy") }
  let(:home) { File.join(dir, "jump-home").tap { FileUtils.mkdir_p(it) } }
  let(:vendor) { File.join(REPO_ROOT, "vendor", "bundle", "ruby", "3.4.0") }
  let(:clean) do
    { "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil,
      "BUNDLER_VERSION" => nil, "GEM_HOME" => nil, "QUAACKS_DEV_CHECKOUT" => nil, "HOME" => home }
  end
  # Where `gem install --user-install` puts gems for this HOME.
  let(:user_dir) do
    out, status = Open3.capture2(clean.merge("GEM_PATH" => nil), RbConfig.ruby, "-e", "print Gem.user_dir",
                                 unsetenv_others: false)
    raise "no user gem dir" unless status.success?

    out
  end
  let(:ssh) { fake_ssh }

  after { FileUtils.rm_rf(dir) }

  # Takes ssh's options up to --, then the host, then runs the joined remote
  # command with sh in the fake jump server's HOME, as sshd would, with the
  # user gem bin dir on PATH, as DESIGN.md says to set up. It logs each
  # remote command, one per line, to dir/remote. The login shell is bash:
  # getent is a stub that can't answer, so SHELL decides. With probe: false,
  # the diagnosis probe (`sh -s`) fails, as it would if ssh dropped. With
  # expired: true, every call after gem install, the version check and
  # the transport's `true` probe, exits 255, as when the ssh login expires
  # during the install.
  # With slow: true, the version check hangs. A remote command that starts
  # with one of fail_on prints "boom" and exits 1. One that starts with one
  # of fail_after runs, then exits 1, so ssh fails after its whole stdout.
  def fake_ssh(path: true, probe: true, expired: false, slow: false, fail_on: [], fail_after: [])
    script = File.join(dir, "ssh")
    bin = path ? "#{user_dir}/bin:" : ""
    File.write(script, <<~SH)
      #!/bin/sh
      while [ "$#" -gt 0 ]; do arg=$1; shift; [ "$arg" = "--" ] && break; done
      shift
      #{remote_env.map { |k, v| v ? "export #{k}='#{v}'" : "unset #{k}" }.join("\n")}
      export PATH='#{bin}#{stubs}:#{RbConfig::CONFIG["bindir"]}':/usr/bin:/bin SHELL=/bin/bash
      printf '%s\\n' "$*" >> '#{dir}/remote'
      #{"[ \"$*\" = 'sh -s' ] && exit 255" unless probe}
      #{"case \"$*\" in quaacks*|true) exit 255 ;; esac" if expired}
      #{"case \"$*\" in quaacks*) exec sleep 30 ;; esac" if slow}
      #{fail_on.map { "case \"$*\" in '#{it}'*) echo boom; exit 1 ;; esac" }.join("\n")}
      #{fail_after.map { "case \"$*\" in '#{it}'*) cd \"$HOME\" && sh -c \"$*\"; exit 1 ;; esac" }.join("\n")}
      cd "$HOME" && exec sh -c "$*"
    SH
    script.tap { FileUtils.chmod(0o755, it) }
  end

  let(:stubs) do
    File.join(dir, "stubs").tap do |stubs|
      FileUtils.mkdir_p(stubs)
      File.write(File.join(stubs, "getent"), "#!/bin/sh\nexit 2\n")
      FileUtils.chmod(0o755, File.join(stubs, "getent"))
    end
  end

  # The jump server session's environment: outside any bundle, with the
  # user gem dir and vendor/bundle as its gems, plus gem_home, when it's
  # set, as GEM_HOME, the way an rbenv or asdf Ruby can set it.
  let(:gem_home) { nil }

  def remote_env = clean.merge("GEM_PATH" => [user_dir, gem_home, vendor].compact.join(":"), "GEM_HOME" => gem_home)

  def deploy(ssh: self.ssh) = described_class.new(host: "jump-1", ssh:).call

  it "installs quaacks and quaack-protocol into the user gem dir, and returns the version it runs as" do
    expect(deploy).to eq(Quaack::Driver::ENCLAVE_VERSION)

    installed = Dir.children(File.join(user_dir, "gems")).sort
    expect(installed).to eq(["quaack-protocol-#{Quaack::Protocol::VERSION}",
                             "quaacks-#{Quaack::Driver::ENCLAVE_VERSION}"])
    expect(File.executable?(File.join(user_dir, "bin", "quaacks"))).to be(true)
    remote = File.read(File.join(dir, "remote"))
    expect(remote).to include("gem install --user-install --no-document")
    expect(remote).not_to include("sudo")
  end

  it "prints each step on stdout as it starts, and what it installed last" do
    out = StringIO.new
    err = StringIO.new
    ssh
    status = with_env("PATH" => "#{dir}:#{ENV.fetch("PATH")}") do
      described_class.main(["--host", "jump-1"], stdout: out, stderr: err)
    end

    expect([status, err.string]).to eq([0, ""])
    protocol = "quaack-protocol-#{Quaack::Protocol::VERSION}.gem"
    quaacks = "quaacks-#{Quaack::Driver::ENCLAVE_VERSION}.gem"
    expect(out.string).to eq(<<~OUT)
      quaack deploy: building #{protocol}
      quaack deploy: building #{quaacks}
      quaack deploy: copying #{protocol} to jump-1
      quaack deploy: copying #{quaacks} to jump-1
      quaack deploy: running gem install on jump-1. It builds pg_query from source, which can take a few minutes.
      quaack deploy: checking quaacks on jump-1
      quaack deploy: installed quaacks #{Quaack::Driver::ENCLAVE_VERSION} on jump-1
    OUT
  end

  it "says what line to add, and where, when quaacks installed but isn't on PATH for non-interactive ssh" do
    bin = "#{user_dir}/bin"
    expect { deploy(ssh: fake_ssh(path: false)) }.to raise_error(described_class::Error) { |e|
      expect(e.message).to eq(<<~MSG.chomp)
        installed quaacks #{Quaack::Driver::ENCLAVE_VERSION} on jump-1, but quaacks isn't installed on jump-1, or isn't on PATH for non-interactive ssh there.
        jump-1's login shell is bash, and #{bin}, where quaacks is, isn't on PATH for non-interactive ssh. Add this line to ~/.bashrc on jump-1, above any line that returns early for non-interactive shells:
          export PATH="#{bin}:$PATH"
        Check with: ssh jump-1 quaacks --version
      MSG
    }
    expect(Dir.children(File.join(user_dir, "gems"))).to include("quaacks-#{Quaack::Driver::ENCLAVE_VERSION}")
  end

  # Task 20261006-8: deploy doesn't read enclave_timeout_seconds, so its
  # timeout doesn't say to raise it, nor that quaacks isn't installed.
  it "says the version check timed out, without naming a setting deploy doesn't read" do
    deployer = described_class.new(host: "jump-1", ssh: fake_ssh(slow: true), version_timeout: 1)
    expect { deployer.call }.to raise_error(described_class::Error) { |e|
      expect(e.message).to eq("installed quaacks #{Quaack::Driver::ENCLAVE_VERSION} on jump-1, but timeout: the " \
                              "enclave call timed out after 0h00m01s")
    }
  end

  it "falls back to the general advice when the diagnosis probe fails" do
    expect { deploy(ssh: fake_ssh(path: false, probe: false)) }.to raise_error(described_class::Error) { |e|
      expect(e.message).to eq("installed quaacks #{Quaack::Driver::ENCLAVE_VERSION} on jump-1, but quaacks isn't " \
                              "installed on jump-1, or isn't on PATH for non-interactive ssh there. If it isn't on " \
                              "PATH for non-interactive ssh, put the user gem bin dir on PATH there (DESIGN.md, " \
                              "\"Deploying the enclave\").")
    }
  end

  it "fails cleanly, saying to check ssh and deploy again, when ssh fails at the version check" do
    out = StringIO.new
    err = StringIO.new
    fake_ssh(expired: true)
    status = with_env("PATH" => "#{dir}:#{ENV.fetch("PATH")}") do
      described_class.main(["--host", "jump-1"], stdout: out, stderr: err)
    end

    expect([status, err.string]).to eq(
      [1, "quaack deploy failed: installed quaacks #{Quaack::Driver::ENCLAVE_VERSION} on jump-1, but ssh_failed: " \
          "couldn't ssh to the jump server; check your ssh login or network, then run " \
          "`quaack deploy --host jump-1` again\n"]
    )
    expect(File.read(File.join(dir, "remote")).lines.last(2)).to eq(["quaacks version\n", "true\n"])
  end

  it "fails, naming the host, when gem install fails there" do
    broken = File.join(dir, "broken-ssh")
    File.write(broken, "#!/bin/sh\ncat >/dev/null\necho 'ERROR: could not build pg_query'\nexit 1\n")
    FileUtils.chmod(0o755, broken)

    expect { deploy(ssh: broken) }.to raise_error(described_class::Error, /on jump-1.*could not build pg_query/m)
  end

  # gem build runs outside whatever bundle the driver runs in. The fake
  # checkout's first gemspec records which of the parent's Bundler
  # variables it sees. Its second gemspec is missing, so the deploy stops
  # there, before ssh.
  it "runs gem build without the parent's Bundler variables" do
    checkout = File.join(dir, "checkout")
    seen = File.join(dir, "seen")
    names = %w[RUBYOPT BUNDLE_GEMFILE BUNDLE_BIN_PATH BUNDLER_SETUP BUNDLER_VERSION]
    FileUtils.mkdir_p(File.join(checkout, "protocol"))
    File.write(File.join(checkout, described_class::GEMS.fetch("quaack-protocol")), <<~RUBY)
      File.write(#{seen.inspect}, #{names.inspect}.select { ENV.key?(it) }.join(","))
      Gem::Specification.new { |s| s.name = "quaack-protocol"; s.version = "0.0.1"; s.summary = "fake"; s.authors = ["x"] }
    RUBY
    planted = { "RUBYOPT" => "-W0", "BUNDLE_GEMFILE" => File.join(dir, "Gemfile"), "BUNDLE_BIN_PATH" => "/nowhere",
                "BUNDLER_SETUP" => "/nowhere", "BUNDLER_VERSION" => Bundler::VERSION }
    saved = ENV.to_h.slice(*names)
    begin
      ENV.update(planted)
      expect { described_class.new(host: "jump-1", ssh:, checkout:).call }
        .to raise_error(described_class::Error, /enclave.*isn't there/)
    ensure
      names.each { ENV.delete(it) }
      ENV.update(saved)
    end

    expect(File.read(seen)).to eq("")
  end

  # Task 20260929-20: deploy keeps the version it installed and the highest
  # one older than that, and removes the rest of quaacks and quaack-protocol.
  describe "removing old versions" do
    let(:current) { Quaack::Driver::ENCLAVE_VERSION }
    let(:protocol) { Quaack::Protocol::VERSION }
    let(:out) { StringIO.new }
    let(:deploy_dir) { File.join(home, ".quaack", "deploy") }

    # Installs a stand-in gem of name and version into the user gem dir. It
    # has no files and no executable, so the bin/quaacks wrapper still runs
    # the real quaacks.
    def plant(name, version)
      _, status = Open3.capture2e(remote_env, RbConfig.ruby, "-S", "gem", "install", "--user-install", "--local",
                                  "--ignore-dependencies", "--no-document", build_plant(name, version))
      raise "gem install failed" unless status.success?
    end

    def build_plant(name, version)
      src = File.join(dir, "plant", "#{name}-#{version}").tap { FileUtils.mkdir_p(it) }
      File.write(File.join(src, "x.gemspec"),
                 "Gem::Specification.new { |s| s.name = #{name.inspect}; s.version = #{version.inspect}; " \
                 "s.summary = 'x'; s.authors = ['x'] }\n")
      _, status = Open3.capture2e(clean, RbConfig.ruby, "-S", "gem", "build", "x.gemspec", "--output", "x.gem",
                                  chdir: src)
      raise "gem build failed" unless status.success?

      File.join(src, "x.gem")
    end

    def installed(name)
      Dir.children(File.join(user_dir, "specifications")).filter_map { it[/\A#{name}-(\d[^-]*)\.gemspec\z/, 1] }
         .sort_by { Gem::Version.new(it) }
    end

    def deploy_with_progress(ssh: self.ssh) = described_class.new(host: "jump-1", ssh:, stdout: out).call

    def removed_lines = out.string.lines.grep(/removing|leaving/)

    def uninstalls = File.read(File.join(dir, "remote")).lines.grep(/uninstall/)

    # How each uninstall starts: pinned to the user gem dir, which the
    # jump server's ruby resolves.
    let(:pinned) { %({ d=$(ruby -e 'print File.realpath(Gem.user_dir)') && gem uninstall --install-dir "$d") }

    it "removes every older version but the highest, of both gems, saying so for each" do
      %w[0.0.1 0.0.2 0.1.0].each { |v| %w[quaacks quaack-protocol].each { |n| plant(n, v) } }

      expect(deploy_with_progress).to eq(current)

      expect(installed("quaacks")).to eq(["0.1.0", current])
      expect(installed("quaack-protocol")).to eq(["0.1.0", protocol])
      expect(removed_lines).to eq(<<~OUT.lines)
        quaack deploy: removing quaacks 0.0.2 from jump-1
        quaack deploy: removing quaacks 0.0.1 from jump-1
        quaack deploy: removing quaack-protocol 0.0.2 from jump-1
        quaack deploy: removing quaack-protocol 0.0.1 from jump-1
      OUT
      expect(uninstalls).to eq(<<~CMDS.lines)
        #{pinned} -v 0.0.2 quaacks; } 2>&1
        #{pinned} -v 0.0.1 quaacks; } 2>&1
        #{pinned} -v 0.0.2 quaack-protocol; } 2>&1
        #{pinned} -v 0.0.1 quaack-protocol; } 2>&1
      CMDS
    end

    it "keeps the highest older version by version order, not string order, when a release was skipped" do
      %w[0.0.9 0.0.10].each { plant("quaacks", it) }

      deploy_with_progress

      expect(installed("quaacks")).to eq(["0.0.10", current])
      expect(removed_lines).to eq(["quaack deploy: removing quaacks 0.0.9 from jump-1\n"])
    end

    it "leaves a version newer than the one it installed, and says so" do
      %w[0.0.1 0.0.2 99.0.0].each { plant("quaacks", it) }

      deploy_with_progress

      expect(installed("quaacks")).to eq(["0.0.2", current, "99.0.0"])
      expect(removed_lines).to eq(["quaack deploy: leaving quaacks 99.0.0 on jump-1, since it's newer than " \
                                   "#{current}\n", "quaack deploy: removing quaacks 0.0.1 from jump-1\n"])
    end

    it "removes nothing when the version check fails" do
      %w[0.0.1 0.0.2].each { |v| %w[quaacks quaack-protocol].each { |n| plant(n, v) } }
      FileUtils.mkdir_p(deploy_dir)
      File.write(File.join(deploy_dir, "quaacks-0.0.1.gem"), "old")

      expect { deploy_with_progress(ssh: fake_ssh(path: false)) }.to raise_error(described_class::Error)

      expect(installed("quaacks")).to eq(["0.0.1", "0.0.2", current])
      expect(installed("quaack-protocol")).to eq(["0.0.1", "0.0.2", protocol])
      expect(File.exist?(File.join(deploy_dir, "quaacks-0.0.1.gem"))).to be(true)
      expect(File.read(File.join(dir, "remote"))).not_to match(/uninstall|rm /)
      expect(removed_lines).to eq([])
    end

    it "never uninstalls another gem, even an old one in the user gem dir" do
      %w[0.0.1 0.0.2 0.0.3].each { plant("pg_query", it) }
      %w[0.0.1 0.0.2].each { |v| %w[quaacks-extra quaacks].each { |n| plant(n, v) } }

      deploy_with_progress

      expect(installed("pg_query")).to eq(%w[0.0.1 0.0.2 0.0.3])
      expect(installed("quaacks-extra")).to eq(%w[0.0.1 0.0.2])
      expect(uninstalls).to eq(["#{pinned} -v 0.0.1 quaacks; } 2>&1\n"])
    end

    # Task 20261006-22: `gem uninstall --user-install` also removes a
    # matching version from GEM_HOME. Deploy never installs there, so the
    # uninstall is pinned to the user gem dir.
    context "when GEM_HOME is a writable gem dir of its own" do
      let(:gem_home) { File.join(dir, "gem-home") }

      it "uninstalls an old version from the user gem dir only, leaving the same version in GEM_HOME" do
        %w[0.0.1 0.0.2].each { plant("quaacks", it) }
        _, status = Open3.capture2e(remote_env, RbConfig.ruby, "-S", "gem", "install", "--local",
                                    "--ignore-dependencies", "--no-document", build_plant("quaacks", "0.0.1"))
        raise "gem install failed" unless status.success?

        expect(deploy_with_progress).to eq(current)

        expect(installed("quaacks")).to eq(["0.0.2", current])
        expect(Dir.children(File.join(gem_home, "specifications"))).to eq(["quaacks-0.0.1.gemspec"])
      end
    end

    # Task 20261006-22: the new version is live and checked by then, so a
    # cleanup step that fails is a warning, not a failed deploy.
    def deploy_main(fail_on, fail_after: [])
      err = StringIO.new
      fake_ssh(fail_on:, fail_after:)
      status = with_env("PATH" => "#{dir}:#{ENV.fetch("PATH")}") do
        described_class.main(["--host", "jump-1"], stdout: out, stderr: err)
      end
      [status, err.string]
    end

    it "warns, naming the step and host, and still succeeds, when an uninstall fails" do
      %w[0.0.1 0.0.2].each { |v| %w[quaacks quaack-protocol].each { |n| plant(n, v) } }
      FileUtils.mkdir_p(deploy_dir)
      File.write(File.join(deploy_dir, "quaacks-0.0.1.gem"), "old")

      expect(deploy_main(["{ d="])).to eq(
        [0, %w[quaacks quaack-protocol].map do |name|
          "quaack deploy: warning: gem uninstall #{name} 0.0.1 failed on jump-1, but quaacks #{current} is " \
            "installed and checked:\nboom\n"
        end.join]
      )
      expect(out.string.lines.last).to eq("quaack deploy: installed quaacks #{current} on jump-1\n")
      expect(installed("quaacks")).to eq(["0.0.1", "0.0.2", current])
      expect(File.exist?(File.join(deploy_dir, "quaacks-0.0.1.gem"))).to be(false)
    end

    it "warns, naming the step and host, and still succeeds, when listing old versions fails" do
      %w[0.0.1 0.0.2].each { plant("quaacks", it) }

      expect(deploy_main(["ruby -e"])).to eq(
        [0, "quaack deploy: warning: listing old versions failed on jump-1, but quaacks #{current} is installed " \
            "and checked:\nboom\n"]
      )
      expect(out.string.lines.last).to eq("quaack deploy: installed quaacks #{current} on jump-1\n")
      expect(installed("quaacks")).to eq(["0.0.1", "0.0.2", current])
      expect(uninstalls).to eq([])
    end

    # Its stdout lists everything, so only the failure keeps it from
    # removing anything.
    it "removes nothing, not even listed versions and gem files, when the listing prints them but fails" do
      %w[0.0.1 0.0.2].each { |v| %w[quaacks quaack-protocol].each { |n| plant(n, v) } }
      FileUtils.mkdir_p(deploy_dir)
      File.write(File.join(deploy_dir, "quaacks-0.0.1.gem"), "old")

      status, err = deploy_main([], fail_after: ["ruby -e"])

      expect(status).to eq(0)
      expect(err.lines.first).to eq("quaack deploy: warning: listing old versions failed on jump-1, but quaacks " \
                                    "#{current} is installed and checked:\n")
      expect(err).to include("spec:quaacks-0.0.1.gemspec\n", "file:quaacks-0.0.1.gem\n")
      expect(installed("quaacks")).to eq(["0.0.1", "0.0.2", current])
      expect(installed("quaack-protocol")).to eq(["0.0.1", "0.0.2", protocol])
      expect(File.exist?(File.join(deploy_dir, "quaacks-0.0.1.gem"))).to be(true)
      expect(File.read(File.join(dir, "remote"))).not_to match(/uninstall|rm /)
    end

    it "warns with the remote ruby's own message, and still succeeds, when it can't resolve the user gem dir" do
      %w[0.0.1 0.0.2].each { plant("quaacks", it) }
      File.write(File.join(stubs, "ruby"), <<~SH)
        #!/bin/sh
        case "$*" in *File.realpath*) echo 'realpath: No such file or directory - planted' >&2; exit 1 ;; esac
        exec '#{RbConfig.ruby}' "$@"
      SH
      FileUtils.chmod(0o755, File.join(stubs, "ruby"))

      expect(deploy_main([])).to eq(
        [0, "quaack deploy: warning: gem uninstall quaacks 0.0.1 failed on jump-1, but quaacks #{current} is " \
            "installed and checked:\nrealpath: No such file or directory - planted\n"]
      )
      expect(installed("quaacks")).to eq(["0.0.1", "0.0.2", current])
    end

    it "warns, naming the step and host, and still succeeds, when removing old gem files fails" do
      %w[0.0.1 0.0.2].each { plant("quaacks", it) }
      FileUtils.mkdir_p(deploy_dir)
      File.write(File.join(deploy_dir, "quaacks-0.0.1.gem"), "old")

      expect(deploy_main(["rm -f"])).to eq(
        [0, "quaack deploy: warning: removing old gem files failed on jump-1, but quaacks #{current} is installed " \
            "and checked:\nboom\n"]
      )
      expect(out.string.lines.last).to eq("quaack deploy: installed quaacks #{current} on jump-1\n")
      expect(installed("quaacks")).to eq(["0.0.2", current])
      expect(File.exist?(File.join(deploy_dir, "quaacks-0.0.1.gem"))).to be(true)
    end

    it "parses only plain versions of its own two gems out of the listing" do
      listing = ["spec:quaacks-0.0.1.gemspec", "spec:quaacks-0.0.2;touch pwned.gemspec", "spec:quaacks-$(id).gemspec",
                 "spec:quaacks-extra-0.0.1.gemspec", "spec:pg-1.6.0.gemspec", "spec:quaack-protocol-0.1.10.gemspec",
                 "file:quaacks-0.0.1.gem", "file:quaacks-0.0.1.gem; rm -rf ~", "file:notes.txt",
                 "noise quaacks-0.0.3.gemspec"].join("\n")
      expect(Quaack::Driver::DeployCleanup.parse_listing(listing)).to eq(
        specs: { "quaacks" => [Gem::Version.new("0.0.1")], "quaack-protocol" => [Gem::Version.new("0.1.10")] },
        files: ["quaacks-0.0.1.gem"]
      )
    end

    it "compares versions as versions: 0.1.10 is newer than 0.1.9" do
      versions = %w[0.1.8 0.1.9 0.1.10 0.1.12].map { Gem::Version.new(it) }
      expect(Quaack::Driver::DeployCleanup.plan(versions, Gem::Version.new("0.1.11")))
        .to eq(remove: %w[0.1.9 0.1.8].map { Gem::Version.new(it) }, newer: [Gem::Version.new("0.1.12")])
    end

    it "clears old gem files out of ~/.quaack/deploy, keeping the ones it just installed and anything else" do
      FileUtils.mkdir_p(deploy_dir)
      %w[quaacks-0.0.1.gem quaack-protocol-0.0.1.gem quaacks-0.0.2.gem notes.txt].each do |name|
        File.write(File.join(deploy_dir, name), "old")
      end

      deploy_with_progress

      expect(Dir.children(deploy_dir).sort)
        .to eq(["notes.txt", "quaack-protocol-#{protocol}.gem", "quaacks-#{current}.gem"])
      expect(out.string.lines.grep(/gem files/))
        .to eq(["quaack deploy: removing 3 old gem files from ~/.quaack/deploy on jump-1\n"])
    end
  end

  # The installed quaacks refuses to run where the driver gem is installed
  # too, the wrong deploy the exe's guard catches.
  it "leaves a quaacks that refuses to run once the driver gem is installed beside it" do
    deploy
    gem = File.join(dir, "driver.gem")
    _, status = Open3.capture2e(clean, RbConfig.ruby, "-S", "gem", "build", "quaack-driver.gemspec", "--output", gem,
                                chdir: File.join(REPO_ROOT, "driver"))
    raise "gem build failed" unless status.success?

    ssh_env = remote_env
    _, status = Open3.capture2e(ssh_env, RbConfig.ruby, "-S", "gem", "install", "--user-install", "--no-document",
                                "--ignore-dependencies", gem)
    raise "gem install failed" unless status.success?

    out, = Open3.capture2(ssh_env, File.join(user_dir, "bin", "quaacks"), "--version")
    expect(out).to eq(%({"type":"error","rule":"driver_present"}\n))
  end
end
