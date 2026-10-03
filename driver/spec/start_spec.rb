# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"
require "tmpdir"
require "quaack/driver/start"

# `quaack start`: finds the jump server with the configured jump_command,
# runs `quaacks intake` there over ssh, and remembers which jump server holds
# the run. ssh is the fake from EnclaveCommands, and the remote quaacks a
# probe step that records what it was given.
RSpec.describe Quaack::Driver::Start do
  let(:dir) { Dir.mktmpdir("quaack-driver-start") }
  let(:home) { File.join(dir, "home").tap { FileUtils.mkdir_p(it) } }
  let(:ssh) { EnclaveCommands.fake_ssh(dir, remote_bin: File.join(dir, "remote-bin")) }
  let(:run_id) { "20260926T010203Z-0123abcd" }

  after { FileUtils.rm_rf(dir) }

  def configure(command)
    FileUtils.mkdir_p(File.join(home, ".quaack"))
    File.write(File.join(home, ".quaack", "driver.json"), JSON.generate("jump_command" => command))
  end

  # A remote quaacks that answers intake with the probe below, and version
  # as the real enclave script does, with version.
  def remote_intake(run_id: self.run_id, version: nil)
    body = "File.write(#{File.join(dir, "got").inspect}, JSON.generate(inputs[:options])); " \
           "[{ type: :run, run_id: #{run_id.inspect} }]"
    command = EnclaveCommands.probe(dir, body, options: { "query" => :value, "plan" => :value, "server" => :value })
    # The probe step answers as intake: the wrapper swaps the subcommand.
    bin = EnclaveCommands.remote_quaacks(File.join(dir, "remote-bin"), command)
    wrapper = File.join(bin, "quaacks")
    File.write(wrapper, File.read(wrapper).sub("exec ", "#{version_answer(version)}[ \"$1\" = intake ] || exit 9; " \
                                                        "shift; exec ")
                                          .sub(" \"$@\"", " probe \"$@\""))
  end

  # Shell that answers `quaacks version`: with the real script, or, given a
  # version, with a version line naming it.
  def version_answer(version)
    reply = if version
              "printf '%s\\n' '{\"type\":\"version\",\"version\":\"#{version}\"}' '{\"type\":\"done\"}'"
            else
              "#{Shellwords.join(EnclaveCommands.quaacks)} version"
            end
    "if [ \"$1\" = version ]; then #{reply}; exit; fi\n"
  end

  it "checks the jump server's quaacks version before intake, and refuses a mismatch" do
    configure("echo jump-1")
    remote_intake(version: "0.0.9")

    expect { start }.to raise_error(Quaack::Driver::EnclaveVersion::Mismatch, /jump-1 has quaacks 0\.0\.9/)
    expect(File.exist?(File.join(dir, "got"))).to be(false)
  end

  def start(server: "prod-1", query: "/q q.sql", plan: "/p.json", **)
    described_class.new(home:, ssh:, **).call(server:, query:, plan:)
  end

  it "runs intake on the host jump_command prints for the server, and records the run's jump host" do
    configure("printf 'jump-%s\\n' {server}")
    remote_intake

    expect(start).to eq(run_id)
    expect(EnclaveCommands.ssh_argv(dir)).to include("jump-prod-1")
    expect(JSON.parse(File.read(File.join(dir, "got"))))
      .to eq("query" => "/q q.sql", "plan" => "/p.json", "server" => "prod-1")
    expect(Quaack::Driver::Runs.new(home).host(run_id)).to eq("jump-prod-1")
  end

  it "passes the server to jump_command as one quoted shell word" do
    pwned = File.join(dir, "pwned")
    configure("printf '%s' {server} > #{File.join(dir, "arg")}; echo jump-1")
    remote_intake

    start(server: "a b; touch #{pwned}")
    expect(File.read(File.join(dir, "arg"))).to eq("a b; touch #{pwned}")
    expect(File.exist?(pwned)).to be(false)
  end

  it "refuses a query or plan path under this laptop's home before ssh" do
    configure("echo jump-1")
    remote_intake

    message = "query looks like a path on this laptop; --query and --plan are paths on the jump server. " \
              "Give a path relative to your home there, such as q/query.sql, or an absolute path there."
    expect { start(query: File.join(home, "q", "query.sql")) }
      .to raise_error(Quaack::Driver::Start::UsageError, message)
    expect(File.exist?(File.join(dir, "got"))).to be(false)

    message = message.sub("query", "plan")
    expect { start(plan: File.join(home, "q", "plan.json")) }
      .to raise_error(Quaack::Driver::Start::UsageError, message)
    expect(File.exist?(File.join(dir, "got"))).to be(false)
  end

  it "refuses output that isn't one ssh host, a failing command, and a missing config" do
    { "echo '-oProxyCommand=x'" => "jump_command_bad_output", "echo 'a b'" => "jump_command_bad_output",
      "printf 'a\\nb\\n'" => "jump_command_bad_output", "true" => "jump_command_bad_output",
      "echo jump-1; exit 3" => "jump_command_failed" }.each do |command, rule|
      configure(command)
      expect { start }.to raise_error(Quaack::Driver::Start::Error, rule), command
    end
    FileUtils.rm_rf(File.join(home, ".quaack"))
    expect { start }.to raise_error(Quaack::Driver::Start::Error, "no_driver_config")
  end

  it "refuses a config without a one-line jump_command" do
    path = File.join(home, ".quaack", "driver.json")

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate({}))
    expect { start }.to raise_error(Quaack::Driver::Start::Error, "bad_driver_config: #{path}: no jump_command")

    ["", "echo a\necho b", nil].each do |command|
      configure(command)
      expect { start }.to raise_error(Quaack::Driver::Start::Error,
                                      "bad_driver_config: #{path}: jump_command isn't one non-blank line")
    end
  end

  it "refuses a config that isn't a JSON object" do
    path = File.join(home, ".quaack", "driver.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{\n  \"jump_command\": \"ok\",\n    SENTINEL-VALUE\n}")
    expect { start }.to raise_error(Quaack::Driver::Start::Error,
                                    "bad_driver_config: #{path}: not valid JSON (line 3, column 5)")
    begin
      start
    rescue Quaack::Driver::Start::Error => e
      expect(e.message).not_to include("SENTINEL-VALUE")
    end

    ["[1]", "null"].each do |text|
      File.write(path, text)
      expect { start }.to raise_error(Quaack::Driver::Start::Error,
                                      "bad_driver_config: #{path}: not a JSON object")
    end
  end

  # chmod 000 can't stop root reading the file, so the example is skipped
  # where the file stays readable.
  it "refuses a config it can't read" do
    configure("echo jump-1")
    path = File.join(home, ".quaack", "driver.json")
    File.chmod(0o000, path)
    skip "this user can read a file with mode 000" if File.readable?(path)

    expect { start }.to raise_error(Quaack::Driver::Start::Error,
                                    "bad_driver_config: #{path}: can't read it (permission denied)")
  end

  # A ~/.quaack that exists but can't be read is refused the same way,
  # not taken for a missing config.
  it "refuses a ~/.quaack it can't read" do
    quaack = File.join(home, ".quaack")
    configure("echo jump-1")
    File.chmod(0o000, quaack)
    skip "this user can read a directory with mode 000" if File.readable?(File.join(quaack, "driver.json"))

    expect { start }.to raise_error(Quaack::Driver::Start::Error,
                                    "bad_driver_config: #{File.join(quaack, "driver.json")}: " \
                                    "can't read it (permission denied)")
  ensure
    File.chmod(0o700, quaack)
  end

  it "refuses a driver.json that isn't a file, not taking it for a missing one" do
    path = File.join(home, ".quaack", "driver.json")
    FileUtils.mkdir_p(path)
    expect { start }.to raise_error(Quaack::Driver::Start::Error, "bad_driver_config: #{path}: can't read it")
  end

  it "counts a ~/.quaack without a driver.json, or that isn't a directory, as no config" do
    quaack = File.join(home, ".quaack")
    FileUtils.mkdir_p(quaack)
    expect { start }.to raise_error(Quaack::Driver::Start::Error, "no_driver_config")
    FileUtils.rm_rf(quaack)
    File.write(quaack, "")
    expect { start }.to raise_error(Quaack::Driver::Start::Error, "no_driver_config")
  end

  it "times out a jump_command that runs too long" do
    configure("sleep 5; echo jump-1")
    expect { start(jump_timeout: 0.3) }.to raise_error(Quaack::Driver::Start::Error, "jump_command_timed_out")
  end

  it "kills what jump_command started, not just its shell, on a timeout" do
    pid_file = File.join(dir, "sleep.pid")
    configure("sleep 30 & echo $! > #{pid_file}; wait")
    expect { start(jump_timeout: 0.5) }.to raise_error(Quaack::Driver::Start::Error, "jump_command_timed_out")

    pid = Integer(File.read(pid_file))
    alive = 20.times.all? do
      Process.kill(0, pid)
      sleep 0.05
      true
    rescue Errno::ESRCH
      false
    end
    Process.kill("KILL", pid) if alive
    expect(alive).to be(false)
  end

  it "refuses to record a run ID that isn't one, and writes nothing" do
    runs = Quaack::Driver::Runs.new(home)
    expect { runs.record("../x", "jump-1") }.to raise_error(ArgumentError, "not a run ID")
    expect(Dir.exist?(File.join(home, ".quaack", "runs"))).to be(false)
  end

  it "refuses a run ID that isn't one, and records nothing" do
    configure("echo jump-1")
    remote_intake(run_id: "../../etc/x")

    expect { start }.to raise_error(Quaack::Driver::Start::Error, "bad_run_id")
    expect(Dir.exist?(File.join(home, ".quaack", "runs"))).to be(false)
  end

  it "reads back no host for a run it never recorded" do
    expect(Quaack::Driver::Runs.new(home).host(run_id)).to be_nil
  end
end
