# frozen_string_literal: true

require "fileutils"
require "json"
require "tmpdir"
require "quaack/driver/burndown"
require "quaack/driver/llm"

# A fake `claude`: records its argv, stdin, the system prompt file, and its
# working directory, then prints QUAACK_FAKE_CLAUDE_OUT (canned JSON) and
# exits with QUAACK_FAKE_CLAUDE_STATUS.
FAKE_CLAUDE_SCRIPT = <<~RUBY
  require "json"
  i = ARGV.index("--system-prompt-file")
  system_path = i && ARGV[i + 1]
  record = {
    argv: ARGV,
    cwd: Dir.pwd,
    stdin: $stdin.read,
    system_path: system_path,
    system: system_path && File.read(system_path),
    system_mode: system_path && format("%o", File.stat(system_path).mode & 0777)
  }
  File.write(ENV.fetch("QUAACK_FAKE_CLAUDE_RECORD"), JSON.generate(record)) if ENV["QUAACK_FAKE_CLAUDE_RECORD"]
  warn ENV["QUAACK_FAKE_CLAUDE_ERR"] if ENV["QUAACK_FAKE_CLAUDE_ERR"]
  sleep Float(ENV["QUAACK_FAKE_CLAUDE_SLEEP"]) if ENV["QUAACK_FAKE_CLAUDE_SLEEP"]
  print ENV.fetch("QUAACK_FAKE_CLAUDE_OUT")
  exit Integer(ENV.fetch("QUAACK_FAKE_CLAUDE_STATUS", "0"))
RUBY

RSpec.describe "the claude_cli adapter" do
  let(:burndown) { Quaack::Driver::Burndown.new }
  let(:messages) { [{ role: "user", content: "Propose indexes." }] }
  let(:schema) do
    { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"],
      additionalProperties: false }
  end

  around do |example|
    Dir.mktmpdir("quaack-claude-cli-spec") do |dir|
      @dir = dir
      @bin = File.join(dir, "bin")
      FileUtils.mkdir_p(@bin)
      File.write(File.join(@bin, "claude"), "#!/usr/bin/env ruby\n#{FAKE_CLAUDE_SCRIPT}")
      File.chmod(0o755, File.join(@bin, "claude"))
      example.run
    end
  end

  def record_path = File.join(@dir, "record.json")
  def record = JSON.parse(File.read(record_path))

  def success(text, usage: { input_tokens: 10, cache_read_input_tokens: 5, cache_creation_input_tokens: 2,
                             output_tokens: 7 })
    JSON.generate(type: "result", subtype: "success", is_error: false, result: text, usage:,
                  session_id: "s", total_cost_usd: 0.01)
  end

  def client(block = {})
    settings = Quaack::Driver::LLM.settings({ "provider" => "claude_cli", **block }, env: {})
    Quaack::Driver::LLM::Client.new(settings:, burndown:)
  end

  # out is the fake's stdout; status, err, and sleep its exit status, stderr, and delay.
  def ask(out:, block: {}, provider: nil, **fake)
    env = { "PATH" => "#{@bin}:#{ENV.fetch("PATH")}", "QUAACK_FAKE_CLAUDE_RECORD" => record_path,
            "QUAACK_FAKE_CLAUDE_OUT" => out, "QUAACK_FAKE_CLAUDE_STATUS" => fake.fetch(:status, 0).to_s,
            "QUAACK_FAKE_CLAUDE_ERR" => fake[:err], "QUAACK_FAKE_CLAUDE_SLEEP" => fake[:sleep]&.to_s }
    with_env(env) do
      client(block).ask(step: "llm-index-ideas", system: "You propose indexes.", messages:, max_tokens: 1000,
                        schema:, **(provider ? { provider: } : {}))
    end
  end

  def ask_error(**)
    ask(**)
    raise "expected an LLM::Error"
  rescue Quaack::Driver::LLM::Error => e
    e
  end

  it "defaults to claude-opus-5-5" do
    expect(Quaack::Driver::LLM.settings({ "provider" => "claude_cli" }, env: {}).model).to eq("claude-opus-5-5")
  end

  it "runs claude in print mode with JSON output, no tools, no saved session, and the prompt on stdin" do
    expect(ask(out: success('{"ddl":[]}'))).to eq("ddl" => [])

    argv = record.fetch("argv")
    expect(argv.first(3)).to eq(["-p", "--output-format", "json"])
    expect(argv.each_cons(2).to_a).to include(["--model", "claude-opus-5-5"], ["--tools", ""])
    expect(argv).to include("--no-session-persistence", "--strict-mcp-config", "--disable-slash-commands")
    expect(argv.join(" ")).not_to include("Propose indexes")
    expect(record["stdin"]).to include("Conversation:\n[user]\nPropose indexes.")
    expect(record["stdin"]).to include("JSON schema:\n#{JSON.pretty_generate(schema)}")
    expect(record["system"]).to include("You propose indexes.")
    expect(record["system_mode"]).to eq("600")
    expect(File.exist?(record["cwd"])).to be(false)
  end

  it "substitutes the model and prompt file into a configured template" do
    template = [File.join(@bin, "claude"), "-p", "--model={model}", "--system-prompt-file", "{system_file}",
                "--x", "{prompt_file}"]
    ask(out: success('{"ddl":[]}'), block: { "model" => "claude-sonnet-5-5", "command_template" => template })

    argv = record.fetch("argv")
    expect(argv).to include("--model=claude-sonnet-5-5")
    expect(File.basename(argv.last)).to eq("prompt.md")
  end

  it "reports the reply's tokens, cache reads and writes in input" do
    ask(out: success('{"ddl":[]}'), provider: "claude")

    usage = burndown.llm_usage.fetch("claude")
    expect(usage.slice("input", "output", "cached")).to eq("input" => 17, "output" => 7, "cached" => 5)
  end

  it "maps output that isn't the JSON result to llm_bad_response without quoting it" do
    e = ask_error(out: "SENTINEL not json")

    expect(e.rule).to eq("llm_bad_response")
    expect(sans_sizes(e.message)).to eq("llm_bad_response: the claude_cli command's output isn't its JSON result")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  it "maps a result marked as an error to llm_unavailable, naming only its subtype" do
    out = JSON.generate(type: "result", subtype: "error_during_execution", is_error: true, result: "SENTINEL")
    e = ask_error(out:, status: 1)

    expect(e.rule).to eq("llm_unavailable")
    expect(sans_sizes(e.message))
      .to eq("llm_unavailable: the claude_cli command reported an error (error_during_execution)")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  it "maps a login failure to llm_auth with a fixed sentence" do
    out = JSON.generate(type: "result", subtype: "success", is_error: true,
                        result: "Invalid API key sk-ant-SENTINEL · Please run /login")
    e = ask_error(out:, status: 1)

    expect(e.rule).to eq("llm_auth")
    expect(sans_sizes(e.message)).to eq("llm_auth: the claude_cli command says it isn't logged in")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  it "maps a nonzero exit with no JSON to llm_unavailable with a stderr tail, hiding Anthropic keys" do
    e = ask_error(out: "", status: 3, err: "boom with key sk-ant-api03-SENTINEL_x-1")

    expect(e.rule).to eq("llm_unavailable")
    expect(sans_sizes(e.message)).to eq("llm_unavailable: claude_cli exited with status 3: boom with key [token]")
    expect(error_text(e)).not_to include("SENTINEL")
  end

  it "maps a command that runs too long to llm_unavailable" do
    e = ask_error(out: success("{}"), sleep: 5, block: { "timeout_seconds" => 0.5 })

    expect(e.rule).to eq("llm_unavailable")
    expect(sans_sizes(e.message)).to eq("llm_unavailable: the claude_cli command timed out")
  end
end
