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
      "GEM_HOME" => nil, "QUAACKS_DEV_CHECKOUT" => nil, "HOME" => home }
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
  # the diagnosis probe (`sh -s`) fails, as it would if ssh dropped.
  def fake_ssh(path: true, probe: true)
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
  # user gem dir and vendor/bundle as its gems.
  def remote_env = clean.merge("GEM_PATH" => "#{user_dir}:#{vendor}")

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

  it "falls back to the general advice when the diagnosis probe fails" do
    expect { deploy(ssh: fake_ssh(path: false, probe: false)) }.to raise_error(described_class::Error) { |e|
      expect(e.message).to eq("installed quaacks #{Quaack::Driver::ENCLAVE_VERSION} on jump-1, but quaacks isn't " \
                              "installed on jump-1, or isn't on PATH for non-interactive ssh there. If it isn't on " \
                              "PATH for non-interactive ssh, put the user gem bin dir on PATH there (DESIGN.md, " \
                              "\"Deploying the enclave\").")
    }
  end

  it "fails, naming the host, when gem install fails there" do
    broken = File.join(dir, "broken-ssh")
    File.write(broken, "#!/bin/sh\ncat >/dev/null\necho 'ERROR: could not build pg_query'\nexit 1\n")
    FileUtils.chmod(0o755, broken)

    expect { deploy(ssh: broken) }.to raise_error(described_class::Error, /on jump-1.*could not build pg_query/m)
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
