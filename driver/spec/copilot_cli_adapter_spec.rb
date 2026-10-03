# frozen_string_literal: true

require "fileutils"
require "json"
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

RSpec.describe "the copilot_cli adapter" do
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
    client(**).ask(step: "5a-5", system: "You propose indexes.", messages:, max_tokens: 1000, schema:)
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
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    sleep 0.05 while process_alive?(pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    process_alive?(pid)
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
                            "--available-tools=view", "--deny-tool=shell", "--deny-tool=write", "--deny-tool=url",
                            "-s", "--model=fake-model")
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
    expect(burndown.llm_calls).to eq("5a-5" => 2)
  end

  it "maps an absent command to llm_unavailable" do
    template = [File.join(@dir, "missing-copilot"), "{prompt_file}", "{model}"]

    expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
      expect(e.rule).to eq("llm_unavailable")
      expect(sans_sizes(e.message)).to include("the copilot_cli command couldn't be found")
    }
    expect(burndown.llm_calls).to eq("5a-5" => 1)
  end

  it "maps a login failure to llm_auth when stderr is distinctive" do
    command = File.join(@dir, "fake-copilot")
    script(command, 'warn "not logged in to GitHub Copilot"; exit 1')
    template = [command, "{prompt_file}", "{model}"]

    expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e| expect(e.rule).to eq("llm_auth") }
  end

  it "maps a non-zero status to llm_unavailable with a short stderr tail" do
    command = File.join(@dir, "fake-copilot")
    script(command, '100.times { |i| warn "line " + i.to_s }; exit 7')
    template = [command, "{prompt_file}", "{model}"]

    expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
      expect(e.rule).to eq("llm_unavailable")
      expect(sans_sizes(e.message)).to include("copilot_cli exited with status 7")
      expect(sans_sizes(e.message)).to include("line 99")
      expect(sans_sizes(e.message)).not_to include("line 0")
    }
  end

  it "maps empty stdout to llm_bad_response" do
    command = File.join(@dir, "fake-copilot")
    script(command, "exit 0")
    template = [command, "{prompt_file}", "{model}"]

    expect { ask(template: template) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
      expect(e.rule).to eq("llm_bad_response")
    }
  end

  it "kills the process group on timeout" do
    command = File.join(@dir, "fake-copilot")
    grandchild = File.join(@dir, "grandchild.pid")
    begin
      script(command, <<~RUBY)
        require "rbconfig"
        pid = spawn(RbConfig.ruby, "-e", "sleep 60", out: File::NULL, err: File::NULL)
        File.write(#{grandchild.dump}, pid)
        Process.wait(pid)
      RUBY
      template = [command, "{prompt_file}", "{model}"]

      expect { ask(template: template, timeout: 1.0) }.to raise_error(Quaack::Driver::LLM::Error) { |e|
        expect(e.rule).to eq("llm_unavailable")
        expect(sans_sizes(e.message)).to include("timed out")
      }
      expect(burndown.llm_calls).to eq("5a-5" => 1)
      grandchild_pid = Integer(File.read(grandchild))
      expect(process_alive_after_wait?(grandchild_pid)).to be(false)
    ensure
      Process.kill("KILL", grandchild_pid) if grandchild_pid && process_alive?(grandchild_pid)
    end
  end
end
