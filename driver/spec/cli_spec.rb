# frozen_string_literal: true

require "fileutils"
require "shellwords"
require "tmpdir"
require "quaack/driver/cli"
require "quaack/driver/runs"
require "quaack/protocol/version"

RSpec.describe "quaack executable" do
  let(:exe) { File.join(GEM_ROOT, "exe", "quaack") }

  it "prints its version for --version" do
    out, err, status = run_ruby(exe, "--version")

    expect(out).to eq("quaack #{Quaack::Driver::VERSION}\n"), "stderr was #{err}"
    expect(status.exitstatus).to eq(0)
  end

  # Each LLM SDK takes about half a second to load, so the driver loads one
  # only when it builds a client for its provider.
  it "loads no LLM SDK to start" do
    Dir.mktmpdir("quaack-cli-features") do |dir|
      features = File.join(dir, "features")
      dump = "at_exit { File.write(#{features.dump}, $LOADED_FEATURES.join(10.chr)) }; load ARGV.shift"
      out, err, status = run_ruby("-e", dump, exe, "--version")

      expect([out, status.exitstatus]).to eq(["quaack #{Quaack::Driver::VERSION}\n", 0]), "stderr was #{err}"
      loaded = File.read(features).split("\n")
      expect(loaded).to include(end_with("/quaack/driver/llm.rb"))
      expect(loaded.grep(%r{/(anthropic|openai)\.rb\z})).to eq([])
    end
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

    # Task 20261008-51.
    it "passes --database to intake, and records it for the connection note" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "prod-1", "--database",
                                        "app_db", "--query", "/q", "--plan", "/p")

      expect([out, status.exitstatus]).to eq(["20260926T010203Z-0123abcd\n", 0]), err
      expect(File.read(File.join(dir, "ssh-args")))
        .to include("jump-1 quaacks intake --query /q --plan /p --server prod-1 --database app_db")
      expect(Quaack::Driver::Runs.new(dir).where("20260926T010203Z-0123abcd")).to include(database: "app_db")
    end

    it "refuses a bad --database as a usage error before ssh" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p", "--database", "a=b")

      expect([out, status.exitstatus]).to eq(["", 64])
      expect(err).to start_with("quaack start: --database must be")
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    it "refuses a bad --port as a usage error before ssh" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p", "--port", "5432x")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start: --port must be a whole number from 1 to 65535\n", 64])
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    # Tasks 20261004-22 and 20261004-38: argv can hold bytes that aren't UTF-8.
    it "refuses a --port that isn't UTF-8 as a usage error before ssh, without raising" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p", "--port", "54\xff32")

      expect([out, err, status.exitstatus]).to eq(["", "quaack start: --port isn't valid UTF-8\n", 64])
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    it "rejects --port twice, or without a value, with the usage message" do
      [%w[--port 5433 --port 5434], %w[--port]].each do |extra|
        out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                          "--plan", "/p", *extra)

        expect([out, status.exitstatus]).to eq(["", 64]), extra.inspect
        expect(err).to include("quaack start --server <name> --query <file> --plan <file> [--port <n>] " \
                               "[--database <name>] [--captured-at <time>]\n")
      end
      expect(File.exist?(File.join(dir, "ssh-args"))).to be(false)
    end

    # Task 20260928-2.
    it "passes --captured-at, given anywhere among the options, to intake" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--captured-at", "2026-10-01T09:30:00Z",
                                        "--server", "prod-1", "--query", "/q", "--plan", "/p")

      expect([out, status.exitstatus]).to eq(["20260926T010203Z-0123abcd\n", 0]), err
      expect(File.read(File.join(dir, "ssh-args")))
        .to include("jump-1 quaacks intake --query /q --plan /p --server prod-1 --captured-at 2026-10-01T09:30:00Z")
    end

    it "passes no --captured-at to intake when the operator gave none" do
      out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "prod-1", "--query", "/q",
                                        "--plan", "/p")

      expect([out, status.exitstatus]).to eq(["20260926T010203Z-0123abcd\n", 0]), err
      expect(File.read(File.join(dir, "ssh-args"))).not_to include("captured-at")
    end

    # intake checks the value, and its error line holds only the rule, so
    # the driver says what a good one looks like.
    it "says what --captured-at must be when intake refuses it" do
      e = env
      File.write(File.join(dir, "bin", "ssh"), <<~SH)
        #!/bin/sh
        #{version_answer}
        printf '{"type":"error","step":"intake","rule":"bad_captured_at"}\\n'
        exit 70
      SH
      out, err, status = Open3.capture3(e, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                        "--plan", "/p", "--captured-at", "yesterday")

      expect([out, err, status.exitstatus])
        .to eq(["", "quaack start failed: bad_captured_at: --captured-at must be an ISO-8601 time with a zone, " \
                    "such as 2026-10-01T09:30:00Z or 2026-10-01T09:30:00-04:00, no earlier than 1970 and no more " \
                    "than one day ahead of the jump server's clock\n", 1])
    end

    it "rejects --captured-at twice, or without a value, with the usage message" do
      [%w[--captured-at 2026-10-01T09:30:00Z --captured-at 2026-10-01T09:30:00Z], %w[--captured-at]].each do |extra|
        out, err, status = Open3.capture3(env, RbConfig.ruby, exe, "start", "--server", "p", "--query", "/q",
                                          "--plan", "/p", *extra)

        expect([out, status.exitstatus]).to eq(["", 64]), extra.inspect
        expect(err).to include("--plan <file> [--port <n>] [--database <name>] [--captured-at <time>]\n")
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

  # Task 20261007-10: every command's output is only for show, as run's and
  # setup's are, so with stdout and stderr one pipe whose reader has closed
  # (`quaack … 2>&1 | head`), each still exits with its own status. stderr
  # writes through at once, so its messages meet the closed pipe in the
  # process itself.
  describe "when its output's reader has closed" do
    let(:dir) { Dir.mktmpdir("quaack-cli-closed") }

    after { FileUtils.rm_rf(dir) }

    # The executable's exit status with env and argv, its stdout and stderr
    # one pipe whose reader has closed, or the exception it died of. An
    # uncaught Errno::EPIPE exits 1 too, so a status of 1 alone wouldn't
    # show that the command finished.
    def closed_status(env, *argv)
      reader, writer = IO.pipe
      reader.close
      ended = File.join(dir, "ended")
      record = "at_exit { File.write(#{ended.dump}, $!.class.name) }; load ARGV.shift"
      pid = Process.spawn(env, RbConfig.ruby, "-e", record, exe, *argv, out: writer, err: writer)
      writer.close
      status = Process.wait2(pid).last.exitstatus
      (ended = File.read(ended)) == "SystemExit" ? status : ended
    end

    # A driver config whose jump_command fails, so start fails before ssh.
    def failing_jump
      FileUtils.mkdir_p(File.join(dir, ".quaack"))
      File.write(File.join(dir, ".quaack", "driver.json"), '{"jump_command": "exit 1"}')
      { "HOME" => dir }
    end

    it "exits 1 when start fails" do
      expect(closed_status(failing_jump, "start", "--server", "p", "--query", "/q", "--plan", "/p")).to eq(1)
    end

    it "exits with the usage status when start refuses an option" do
      expect(closed_status({ "HOME" => dir }, "start", "--server", "p", "--query", "/q", "--plan", "/p",
                           "--port", "x")).to eq(64)
    end

    it "exits 1 when deploy fails" do
      File.write(File.join(dir, "ssh"), "#!/bin/sh\ncat >/dev/null\nexit 1\n")
      FileUtils.chmod(0o755, File.join(dir, "ssh"))

      expect(closed_status({ "PATH" => "#{dir}:#{ENV.fetch("PATH")}" }, "deploy", "--host", "jump-1")).to eq(1)
    end

    it "exits with the usage status for a usage error" do
      [%w[deploy], %w[start --server p], %w[bogus], ["run", "--run", "\xFF".b]].each do |argv|
        expect(closed_status({ "HOME" => dir }, *argv)).to eq(64), argv.inspect
      end
    end
  end

  # Task 20261004-38: every argument is checked for UTF-8 before any
  # subcommand looks at it, and the refusal names the flag, never the value.
  describe "arguments that aren't UTF-8" do
    let(:dir) { Dir.mktmpdir("quaack-cli-utf8") }
    let(:run_id) { "20260926T010203Z-0123abcd" }
    let(:bad) { "SENTINEL\xff" }

    after { FileUtils.rm_rf(dir) }

    # A fake ssh first on PATH that logs each call, answers version as the
    # expected one, status as inventory done, and each with done, a driver
    # config whose jump_command prints jump-1, a run recorded on jump-1,
    # and a rewrites file.
    def env
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      write_ssh(bin)
      write_home
      { "HOME" => dir, "PATH" => "#{bin}:#{ENV.fetch("PATH")}", "ANTHROPIC_API_KEY" => "test-key" }
    end

    def write_home
      FileUtils.mkdir_p(File.join(dir, ".quaack"))
      File.write(File.join(dir, ".quaack", "driver.json"), '{"jump_command": "echo jump-1"}')
      Quaack::Driver::Runs.new(dir).record(run_id, "jump-1")
      File.write(File.join(dir, "r.sql"), "SELECT 1;\n")
    end

    def write_ssh(bin)
      path = File.join(bin, "ssh")
      File.write(path, <<~SH)
        #!/bin/sh
        printf '%s\\n' "$*" >> '#{dir}/ssh-log'
        case "$*" in
          *" quaacks version") printf '{"type":"version","version":"#{Quaack::Driver::ENCLAVE_VERSION}"}\\n';;
          *" quaacks status "*) printf '{"type":"status","entries":{"inventory":true}}\\n';;
        esac
        printf '{"type":"done"}\\n'
      SH
      FileUtils.chmod(0o755, path)
    end

    def quaack(*argv) = Open3.capture3(env, RbConfig.ruby, exe, *argv, chdir: dir)
    def ssh_log = File.exist?(File.join(dir, "ssh-log")) ? File.read(File.join(dir, "ssh-log")) : ""

    start = %w[start --server prod-1 --query /q --plan /p --port 6543 --captured-at 2026-10-01T09:30:00Z]
    setup = %w[setup --run 20260926T010203Z-0123abcd --host rs-1 --port 6432 --racetrack-db rt --arena-db ar]
    run = %w[run --run 20260926T010203Z-0123abcd --rewrites r.sql --out o.html --host rs-1 --port 6432
             --racetrack-db rt --arena-db ar]
    [start, setup, run, %w[deploy --host jump-1]].each do |argv|
      argv.each_with_index.select { |arg, _| arg.start_with?("--") }.each do |flag, i|
        it "refuses #{argv.first} #{flag} that isn't UTF-8 as a usage error naming the flag, before ssh" do
          out, err, status = quaack(*argv.dup.tap { it[i + 1] = bad })

          expect([out, err, status.exitstatus]).to eq(["", "quaack #{argv.first}: #{flag} isn't valid UTF-8\n", 64])
          expect(ssh_log).to eq("")
        end
      end
    end

    it "refuses a flag name, subcommand, or stray argument that isn't UTF-8 without echoing any argument" do
      [["start", "--server", "p", "--query", "/q", "--plan", "/p", "--po\xffrt", "1"], ["st\xffart"],
       ["setup", "--run", run_id, "--keep\xff"], ["start", "--server", "er", "\xff"]].each do |argv|
        out, err, status = quaack(*argv)

        prefix = argv.first.valid_encoding? ? "quaack #{argv.first}" : "quaack"
        expect([out, err, status.exitstatus]).to eq(["", "#{prefix}: an argument isn't valid UTF-8\n", 64]),
                                                 argv.inspect
      end
      expect(ssh_log).to eq("")
    end

    # Task 20261004-47: --keep takes no value, so what follows it is a
    # stray argument, not --keep's.
    it "doesn't blame a flag that takes no value for the argument after it" do
      out, err, status = quaack("run", "--run", run_id, "--keep", bad)

      expect([out, err, status.exitstatus]).to eq(["", "quaack run: an argument isn't valid UTF-8\n", 64])
      expect(ssh_log).to eq("")
    end

    # Task 20261004-47: flags pair with values left to right, so here
    # --port is --server's value and the bad argument is a stray.
    it "doesn't blame a flag that is itself another flag's value" do
      out, err, status = quaack("start", "--server", "--port", bad)

      expect([out, err, status.exitstatus]).to eq(["", "quaack start: an argument isn't valid UTF-8\n", 64])
      expect(ssh_log).to eq("")
    end

    # Task 20261004-47: --arena-db is setup's and run's, not start's.
    it "doesn't name a flag the subcommand doesn't take" do
      out, err, status = quaack("start", "--server", "prod-1", "--query", "/q", "--plan", "/p", "--arena-db", bad)

      expect([out, err, status.exitstatus]).to eq(["", "quaack start: an argument isn't valid UTF-8\n", 64])
      expect(ssh_log).to eq("")
    end

    # Task 20261004-47: under the C locale Ruby gives argv as binary, which
    # is always a valid encoding, so the check has to read it as UTF-8.
    it "refuses an argument that isn't UTF-8 under LC_ALL=C, and still passes UTF-8 through" do
      out, err, status = Open3.capture3(env.merge("LC_ALL" => "C"), RbConfig.ruby, exe, "start", "--server", "prod-1",
                                        "--query", bad, "--plan", "/p", chdir: dir)

      expect([out, err, status.exitstatus]).to eq(["", "quaack start: --query isn't valid UTF-8\n", 64])
      expect(ssh_log).to eq("")

      out, err, status = Open3.capture3(env.merge("LC_ALL" => "C"), RbConfig.ruby, exe, "start", "--server", "prod-1",
                                        "--query", "r\u00e9sum\u00e9.sql", "--plan", "/p", chdir: dir)
      expect([out, err, status.exitstatus]).to eq(["", "quaack start failed: bad_run_id\n", 1])
    end

    it "still passes non-ASCII UTF-8 through, as in a query file name or a database name" do
      out, err, status = quaack("start", "--server", "prod-1", "--query", "r\u00e9sum\u00e9.sql", "--plan", "/p")

      expect([out, err, status.exitstatus]).to eq(["", "quaack start failed: bad_run_id\n", 1])
      expect(ssh_log).to include("jump-1 quaacks intake --query #{Shellwords.escape("r\u00e9sum\u00e9.sql")} --plan /p")

      quaack("setup", "--run", run_id, "--arena-db", "ar\u00e8ne")
      expect(ssh_log).to include("quaacks run-server --run #{run_id} --arena-db #{Shellwords.escape("ar\u00e8ne")}")
    end
  end
end
