# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "quaack/driver/cli"
require "quaack/protocol/version"

RSpec.describe "quaack executable" do
  let(:exe) { File.join(GEM_ROOT, "exe", "quaack") }

  it "prints its version for --version" do
    out, err, status = run_ruby(exe, "--version")

    expect(out).to eq("quaack #{Quaack::Driver::VERSION}\n"), "stderr was #{err}"
    expect(status.exitstatus).to eq(0)
  end

  describe "start" do
    let(:dir) { Dir.mktmpdir("quaack-cli-start") }

    after { FileUtils.rm_rf(dir) }

    # Shell that answers `quaacks version` as a jump server with version.
    def version_answer(version = Quaack::Driver::ENCLAVE_VERSION)
      "case \"$*\" in *\" quaacks version\") " \
        "printf '{\"type\":\"version\",\"version\":\"#{version}\"}\\n{\"type\":\"done\"}\\n'; exit;; esac"
    end

    # A fake ssh first on PATH that answers version as the expected one and
    # any other call with one run message, and a driver config whose
    # jump_command prints jump-1.
    def env
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p([bin, File.join(dir, ".quaack")])
      File.write(File.join(bin, "ssh"), <<~SH)
        #!/bin/sh
        #{version_answer}
        printf '%s\\n' "$*" > '#{dir}/ssh-args'
        printf '{"type":"run","run_id":"20260926T010203Z-0123abcd"}\\n{"type":"done"}\\n'
      SH
      FileUtils.chmod(0o755, File.join(bin, "ssh"))
      File.write(File.join(dir, ".quaack", "driver.json"), '{"jump_command": "echo jump-1"}')
      { "HOME" => dir, "PATH" => "#{bin}:#{ENV.fetch("PATH")}" }
    end

    it "prints the run ID of the run it started" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "prod-1", "--query", "/q",
                                        "--plan", "/p")

      expect([out, status.exitstatus]).to eq(["20260926T010203Z-0123abcd\n", 0]), err
      expect(File.read(File.join(dir, "ssh-args"))).to include("jump-1 quaacks intake --query /q --plan /p")
    end

    it "refuses a jump server with another quaacks version before intake, pointing to quaack deploy" do
      e = env
      script = File.join(dir, "bin", "ssh")
      File.write(script, File.read(script).sub(version_answer, version_answer("0.0.9")))
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start failed: jump-1 has quaacks 0.0.9, but this driver needs " \
                    "#{Quaack::Driver::ENCLAVE_VERSION}. Run `quaack deploy --host jump-1`.\n", 1])
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    it "prints only the rule when it fails, and exits 1" do
      e = env
      File.write(File.join(dir, ".quaack", "driver.json"), '{"jump_command": "exit 1"}')
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus]).to eq(["", "quaack start failed: jump_command_failed\n", 1])
    end

    it "refuses a query path under this laptop's home as a usage error before ssh" do
      e = env
      laptop_path = File.join(dir, "q", "query.sql")
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", laptop_path,
                                        "--plan", "q/plan.json")

      expect([out, status.exitstatus]).to eq(["", 64])
      expect(err).to eq("quaack start: query looks like a path on this laptop; --query and --plan are paths on " \
                        "the jump server. Give a path relative to your home there, such as q/query.sql, or an " \
                        "absolute path there.\n")
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    # The enclave's error line carries only the rule, so the driver adds the
    # parser note itself.
    it "names the parser's Postgres version when intake can't parse the query" do
      e = env
      File.write(File.join(dir, "bin", "ssh"), <<~SH)
        #!/bin/sh
        #{version_answer}
        printf '{"type":"error","step":"intake","rule":"query_unparsable"}\\n'
        exit 70
      SH
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start failed: query_unparsable (pg_query parses with the Postgres 17 grammar; " \
                    "Postgres 18-only syntax isn't supported yet)\n", 1])
    end

    it "says when ssh can't reach the jump server, and to run start again" do
      e = env
      File.write(File.join(dir, "bin", "ssh"), "#!/bin/sh\nexit 255\n")
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start failed: ssh_failed: couldn't ssh to the jump server; check your ssh login or " \
                    "network, then run `quaack start` again\n", 1])
    end

    # Task 20261004-26: incomplete says how to go on, too.
    it "names the call that died when intake is incomplete, and says to run start again" do
      e = env
      File.write(File.join(dir, "bin", "ssh"), "#!/bin/sh\n#{version_answer}\nexit 3\n")
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start failed: incomplete: quaacks intake ended with exit 3. " \
                    "To go on, run `quaack start` again\n", 1])
    end

    it "passes --port, given anywhere among the options, to intake" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--port", "6543", "--server", "prod-1",
                                        "--query", "/q", "--plan", "/p")

      expect([out, status.exitstatus]).to eq(["20260926T010203Z-0123abcd\n", 0]), err
      expect(File.read(File.join(dir, "ssh-args")))
        .to include("jump-1 quaacks intake --query /q --plan /p --server prod-1 --port 6543")
    end

    it "refuses a bad --port as a usage error before ssh" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p", "--port", "5432x")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start: --port must be a whole number from 1 to 65535\n", 64])
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    # Task 20261004-22: argv can hold bytes that aren't UTF-8.
    it "refuses a --port that isn't UTF-8 as a usage error before ssh, without raising" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p", "--port", "54\xff32")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start: --port must be a whole number from 1 to 65535\n", 64])
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    it "rejects --port twice, or without a value, with the usage message" do
      [%w[--port 5433 --port 5434], %w[--port]].each do |extra|
        out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                          "--plan", "/p", *extra)

        expect([out, status.exitstatus]).to eq(["", 64]), extra.inspect
        expect(err).to include("quaack start --server <name> --query <file> --plan <file> [--port <n>]\n")
      end
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    it "rejects missing options with the usage message" do
      out, err, status = run_ruby(exe, "start", "--server", "p")

      expect([out, status.exitstatus]).to eq(["", 64])
      expect(err).to include("quaack start --server")
    end

    # Setup is quaack setup's, or quaack run's, not start's.
    it "does no setup: it calls quaacks only for version and intake, and takes no run-server flags" do
      e = env
      script = File.join(dir, "bin", "ssh")
      File.write(script, File.read(script).sub("#!/bin/sh\n", "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '#{dir}/log'\n"))
      out, = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q", "--plan", "/p")
      _, _, flagged = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                     "--plan", "/p", "--host", "rs-1")

      expect(out).to eq("20260926T010203Z-0123abcd\n")
      expect(File.readlines(File.join(dir, "log")).map { it[/quaacks (\S+)/, 1] }).to eq(%w[version intake])
      expect(flagged.exitstatus).to eq(64)
    end
  end

  describe "deploy" do
    let(:dir) { Dir.mktmpdir("quaack-cli-deploy") }

    after { FileUtils.rm_rf(dir) }

    # deploy_spec.rb covers a real install. Here ssh fails every remote
    # command, so the CLI's failure path shows.
    it "prints what failed, naming the host, and exits 1" do
      File.write(File.join(dir, "ssh"), "#!/bin/sh\ncat >/dev/null\necho 'no space left'\nexit 1\n")
      FileUtils.chmod(0o755, File.join(dir, "ssh"))
      out, err, status = Open3.capture3({ "PATH" => "#{dir}:#{ENV.fetch("PATH")}" }, RbConfig.ruby, exe,
                                        "deploy", "--host", "jump-1")

      protocol = "quaack-protocol-#{Quaack::Protocol::VERSION}.gem"
      expect([out, status.exitstatus])
        .to eq([<<~OUT, 1])
          quaack deploy: building #{protocol}
          quaack deploy: building quaacks-#{Quaack::Driver::ENCLAVE_VERSION}.gem
          quaack deploy: copying #{protocol} to jump-1
        OUT
      expect(err).to start_with("quaack deploy failed: copying quaack-protocol-")
      expect(err).to include("failed on jump-1:\nno space left\n")
    end

    # ssh succeeds until the remote command matches, then kills the driver
    # while it waits on that step, so only what the driver already flushed
    # reaches the pipe. So the step's line must be out before it runs.
    {
      "the copy" => ["cat >", "copying quaack-protocol-#{Quaack::Protocol::VERSION}.gem to jump-1"],
      "gem install" => ["gem install", "running gem install on jump-1. It builds pg_query from source, " \
                                       "which can take a few minutes."],
      "the check" => ["quaacks version", "checking quaacks on jump-1"]
    }.each do |step, (command, line)|
      it "shows the line for #{step} while it runs, not only when the driver exits" do
        File.write(File.join(dir, "ssh"), <<~SH)
          #!/bin/sh
          cat >/dev/null
          case "$*" in *'#{command}'*) kill -KILL $PPID;; esac
        SH
        FileUtils.chmod(0o755, File.join(dir, "ssh"))
        out, _, status = Open3.capture3({ "PATH" => "#{dir}:#{ENV.fetch("PATH")}" }, RbConfig.ruby, exe,
                                        "deploy", "--host", "jump-1")

        expect(status.termsig).to eq(9)
        expect(out).to end_with("quaack deploy: #{line}\n")
      end
    end

    it "rejects deploy without exactly one --host" do
      [%w[deploy], %w[deploy --host], %w[deploy --host a --host b], %w[deploy --server a]].each do |argv|
        out, err, status = run_ruby(exe, *argv)

        expect([out, err, status.exitstatus]).to eq(["", Quaack::Driver::CLI::USAGE, 64]), argv.inspect
      end
    end
  end

  it "rejects anything else with a usage message on stderr and nothing on stdout" do
    [[], ["--bogus"], %w[some subcommand], %w[--version extra], %w[extra --version],
     %w[--version --version]].each do |argv|
      out, err, status = run_ruby(exe, *argv)

      expect(out).to eq(""), "argv #{argv.inspect} printed #{out.inspect} to stdout"
      expect(err).to eq(Quaack::Driver::CLI::USAGE), "argv #{argv.inspect} printed #{err.inspect}"
      expect(status.exitstatus).to eq(64), "argv #{argv.inspect} exited #{status.exitstatus}"
    end
  end
end
