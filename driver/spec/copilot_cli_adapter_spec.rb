# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/llm"
require_relative "support/llm_client_examples"

FAKE_COPILOT_RECORD_SCRIPT = <<~'RUBY'
  require "json"
  prompt = ARGV.find { |arg| File.file?(arg) }
  prompt ||= ARGV.find { |arg| arg.include?("prompt.md") }.to_s[/\S*prompt\.md/]
  record = {
    argv: ARGV,
    cwd: Dir.pwd,
    custom_dirs: ENV.fetch("COPILOT_CUSTOM_INSTRUCTIONS_DIRS", nil),
    task_wait: ENV.fetch("COPILOT_TASK_WAIT_TIMEOUT_SECONDS", nil),
    prompt_path: prompt,
    prompt: File.read(prompt),
    mode: format("%o", File.stat(prompt).mode & 0777)
  }
  File.write(ENV.fetch("QUAACK_FAKE_COPILOT_RECORD"), JSON.generate(record))
  print ENV.fetch("QUAACK_FAKE_COPILOT_REPLY", "{\"ddl\":[]}")
RUBY

# Writes a reply several pipe buffers long, but holds back its last 4KB until the spec says go. Then it
# writes that tail and exits at once, while a busy spec thread holds the GVL, so the adapter wakes only
# after the exit status is ready and the tail is still in the pipe.
FAKE_COPILOT_TAIL_SCRIPT = <<~RUBY
  dir = ENV.fetch("QUAACK_FAKE_COPILOT_DIR")
  tail = File.binread(File.join(dir, "tail.json"))
  $stdout.write(File.binread(File.join(dir, "head.json")))
  $stdout.flush
  File.write(File.join(dir, "ready"), "")
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  until File.exist?(File.join(dir, "go"))
    exit!(3) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    sleep 0.001
  end
  $stdout.syswrite(tail)
  exit!(0)
RUBY

RSpec.describe "the copilot_cli adapter" do
  # Generous enough for a loaded machine, yet far below the fake grandchild's 60-second sleep, so a real
  # hang on its stdout still trips it.
  def hang_limit = 10.0
  # Long enough for a fake command to start Ruby and spawn its grandchild before the adapter times it out.
  def slow_start_timeout = 3.0

  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:messages) { [{ role: "user", content: "Propose indexes." }] }
  let(:schema) do
    { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"],
      additionalProperties: false }
  end

  around do |example|
    Dir.mktmpdir("quaack-copilot-cli-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  def settings(template: nil, timeout: nil, model: "fake-model")
    block = { "provider" => "copilot_cli", "model" => model }
    block["command_template"] = template if template
    block["timeout_seconds"] = timeout if timeout
    Quaack::Driver::LLM.settings(block, env: {})
  end

  def client(template: nil, timeout: nil, model: "fake-model")
    Quaack::Driver::LLM::Client.new(settings: settings(template:, timeout:, model:), burndown:)
  end

  def ask(**)
    client(**).ask(step: "llm-index-ideas", system: "You propose indexes.", messages:, max_tokens: 1000, schema:)
  end

  def script(path, body)
    File.write(path, "#!/usr/bin/env ruby\n#{body}")
    File.chmod(0o755, path)
  end

  def record_script(path) = script(path, FAKE_COPILOT_RECORD_SCRIPT)

  def read_record
    JSON.parse(File.read(record_path))
  end

  def record_path = File.join(@dir, "record.json")

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def process_alive_after_wait?(pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + hang_limit
    sleep 0.05 while process_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    process_alive?(pid)
  end

  def record_cwd_script(path, body)
    script(path, <<~RUBY)
      File.write(ENV.fetch("QUAACK_FAKE_COPILOT_CWD"), Dir.pwd)
      #{body}
    RUBY
  end

  def recorded_cwd_path = File.join(@dir, "cwd")

  def expect_recorded_cwd_removed
    cwd = File.read(recorded_cwd_path)
    expect(File.exist?(cwd)).to be(false)
  end

  it "runs the command template with the model and a private 0600 prompt file, then removes it" do
    command = File.join(@dir, "fake-copilot")
    record_script(command)
    template = [command, "ask", "{prompt_file}", "--model", "{model}"]

    with_env("QUAACK_FAKE_COPILOT_RECORD" => record_path, "COPILOT_CUSTOM_INSTRUCTIONS_DIRS" => "SENTINEL-DIR") do
      expect(ask(template: template)).to eq("ddl" => [])
    end

    record = read_record
    expect(record["argv"]).to eq(["ask", record["prompt_path"], "--model", "fake-model"])
    expect(record["mode"]).to eq("600")
    expect(record["custom_dirs"]).to be_nil
    expect(record["task_wait"]).to eq(Quaack::Driver::LLM::CopilotCLIAdapter::DEFAULT_TIMEOUT.to_s)
    expect(record["prompt"]).to include("System prompt:\nYou propose indexes.")
    expect(record["prompt"]).to include(Quaack::Driver::LLM::Client::JSON_ONLY)
    expect(record["prompt"]).to include("JSON schema:\n#{JSON.pretty_generate(schema)}")
    expect(record["prompt"]).to include("Conversation:\n[user]\nPropose indexes.")
    expect(File.exist?(record["prompt_path"])).to be(false)
    expect(File.exist?(record["cwd"])).to be(false)
  end

  it "uses a safe default copilot invocation with no custom instructions and only view available" do
    bin = File.join(@dir, "bin")
    FileUtils.mkdir_p(bin)
    record_script(File.join(bin, "copilot"))

    with_env("PATH" => "#{bin}:#{ENV.fetch("PATH")}", "QUAACK_FAKE_COPILOT_RECORD" => record_path) do
      expect(ask).to eq("ddl" => [])
    end

    argv = read_record.fetch("argv")
    expect(argv).to include("--disable-builtin-mcps", "--no-ask-user", "--no-custom-instructions",
                            "--disallow-temp-dir", "--available-tools=view", "--deny-tool=shell",
                            "--deny-tool=write", "--deny-tool=url", "-s", "--model=fake-model")
    expect(argv).to include("-p")
    expect(argv[argv.index("-p") + 1]).to include("prompt.md")
  end

  it "asks once more when the reply does not match the schema, and counts both commands" do
    command = File.join(@dir, "fake-copilot")
    script(command, <<~'RUBY')
      require "json"
      count_path = ENV.fetch("QUAACK_FAKE_COPILOT_COUNT")
      count = File.exist?(count_path) ? Integer(File.read(count_path)) : 0
      File.write(count_path, (count + 1).to_s)
      print(count.zero? ? "{\"indexes\":[]}" : "{\"ddl\":[]}")
    RUBY
    template = [command, "{prompt_file}", "{model}"]

    with_env("QUAACK_FAKE_COPILOT_COUNT" => File.join(@dir, "count")) do
      expect(ask(template: template)).to eq("ddl" => [])
    end
    expect(burndown.llm_calls).to eq("llm-index-ideas" => 2)
  end

  it "maps an absent command to llm_unavailable" do
    template = [File.join(@dir, "missing-copilot"), "{prompt_file}", "{model}"]

    with_env("TMPDIR" => @dir) do
      expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
        expect(e.rule).to eq("llm_unavailable")
        expect(sans_sizes(e.message)).to include("the copilot_cli command couldn't be found")
      }
    end
    expect(burndown.llm_calls).to eq("llm-index-ideas" => 1)
    expect(Dir.children(@dir)).to be_empty
  end

  it "maps a login failure to llm_auth when stderr is distinctive" do
    command = File.join(@dir, "fake-copilot")
    script(command, 'warn "not logged in to GitHub Copilot"; exit 1')
    template = [command, "{prompt_file}", "{model}"]

    expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e| expect(e.rule).to eq("llm_auth") }
  end

  it "maps a non-zero status to llm_unavailable with a short stderr tail" do
    command = File.join(@dir, "fake-copilot")
    record_cwd_script(command, '100.times { |i| warn "line " + i.to_s }; exit 7')
    template = [command, "{prompt_file}", "{model}"]

    with_env("QUAACK_FAKE_COPILOT_CWD" => recorded_cwd_path) do
      expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
        expect(e.rule).to eq("llm_unavailable")
        expect(sans_sizes(e.message)).to include("copilot_cli exited with status 7")
        expect(sans_sizes(e.message)).to include("line 99")
        expect(sans_sizes(e.message)).not_to include("line 0")
      }
    end
    expect_recorded_cwd_removed
  end

  it "maps empty stdout to llm_bad_response" do
    command = File.join(@dir, "fake-copilot")
    record_cwd_script(command, "exit 0")
    template = [command, "{prompt_file}", "{model}"]

    with_env("QUAACK_FAKE_COPILOT_CWD" => recorded_cwd_path) do
      expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
        expect(e.rule).to eq("llm_bad_response")
      }
    end
    expect_recorded_cwd_removed
  end

  def wait_for_file(path)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + hang_limit
    sleep 0.01 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end

  def hold_gvl(seconds)
    stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    nil while Process.clock_gettime(Process::CLOCK_MONOTONIC) < stop
  end

  it "keeps the whole reply when the command writes several pipe buffers and exits at once" do
    ddl = Array.new(4) { |i| "CREATE INDEX idx_#{i} ON t (#{"c" * 80_000})" }
    reply = JSON.generate(ddl:)
    File.write(File.join(@dir, "head.json"), reply[0...-4096])
    File.write(File.join(@dir, "tail.json"), reply[-4096..])
    command = File.join(@dir, "fake-copilot")
    script(command, FAKE_COPILOT_TAIL_SCRIPT)
    template = [command, "{prompt_file}", "{model}"]

    hog = nil
    signal = Thread.new do
      wait_for_file(File.join(@dir, "ready"))
      sleep 0.2 # the adapter drains the head and goes back to waiting
      hog = Thread.new { hold_gvl(0.5) }
      File.write(File.join(@dir, "go"), "")
    end
    result = with_env("QUAACK_FAKE_COPILOT_DIR" => @dir) do
      Timeout.timeout(hang_limit) { ask(template: template, timeout: hang_limit * 3) }
    ensure
      signal.kill
      hog&.kill
    end

    expect(result).to eq("ddl" => ddl)
    # A cut-short reply fails the schema and the client asks again, so one command means the first reply
    # arrived whole.
    expect(burndown.llm_calls).to eq("llm-index-ideas" => 1)
  end

  it "does not hang after a successful command leaks stdout from a detached grandchild" do
    command = File.join(@dir, "fake-copilot")
    grandchild = File.join(@dir, "grandchild.pid")
    begin
      script(command, <<~RUBY)
        require "rbconfig"
        pid = spawn(RbConfig.ruby, "-e", "sleep 60", out: STDOUT, err: STDERR, pgroup: true)
        Process.detach(pid)
        File.write(#{grandchild.dump}, pid)
        print '{"ddl":[]}'
      RUBY
      template = [command, "{prompt_file}", "{model}"]

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Timeout.timeout(hang_limit) { ask(template: template, timeout: hang_limit * 3) }

      expect(result).to eq("ddl" => [])
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < hang_limit
    ensure
      grandchild_pid = Integer(File.read(grandchild)) if File.exist?(grandchild)
      Process.kill("KILL", grandchild_pid) if grandchild_pid && process_alive?(grandchild_pid)
    end
  end

  it "does not hang on timeout when a detached grandchild keeps stdout open" do
    command = File.join(@dir, "fake-copilot")
    grandchild = File.join(@dir, "grandchild.pid")
    begin
      record_cwd_script(command, <<~RUBY)
        require "rbconfig"
        pid = spawn(RbConfig.ruby, "-e", "sleep 60", out: STDOUT, err: STDERR, pgroup: true)
        Process.detach(pid)
        File.write(#{grandchild.dump}, pid)
        sleep 60
      RUBY
      template = [command, "{prompt_file}", "{model}"]

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      with_env("QUAACK_FAKE_COPILOT_CWD" => recorded_cwd_path) do
        expect do
          Timeout.timeout(hang_limit) { ask(template: template, timeout: slow_start_timeout) }
        end.to raise_error(Quaack::Driver::LLM::Error) { |e|
          expect(e.rule).to eq("llm_unavailable")
          expect(sans_sizes(e.message)).to include("timed out")
        }
      end

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < hang_limit
      expect_recorded_cwd_removed
    ensure
      grandchild_pid = Integer(File.read(grandchild)) if File.exist?(grandchild)
      Process.kill("KILL", grandchild_pid) if grandchild_pid && process_alive?(grandchild_pid)
    end
  end

  it "kills the process group on timeout" do
    command = File.join(@dir, "fake-copilot")
    grandchild = File.join(@dir, "grandchild.pid")
    begin
      record_cwd_script(command, <<~RUBY)
        require "rbconfig"
        pid = spawn(RbConfig.ruby, "-e", "sleep 60", out: File::NULL, err: File::NULL)
        File.write(#{grandchild.dump}, pid)
        Process.wait(pid)
      RUBY
      template = [command, "{prompt_file}", "{model}"]

      with_env("QUAACK_FAKE_COPILOT_CWD" => recorded_cwd_path) do
        expect { ask(template: template, timeout: slow_start_timeout) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
          expect(e.rule).to eq("llm_unavailable")
          expect(sans_sizes(e.message)).to include("timed out")
        }
      end
      expect(burndown.llm_calls).to eq("llm-index-ideas" => 1)
      grandchild_pid = Integer(File.read(grandchild))
      expect(process_alive_after_wait?(grandchild_pid)).to be(false)
      expect_recorded_cwd_removed
    ensure
      Process.kill("KILL", grandchild_pid) if grandchild_pid && process_alive?(grandchild_pid)
    end
  end
end
