# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require "quaack/enclave/cli"
require "quaack/enclave/store"

# Stands in for a production value, or for anything untrusted from the
# laptop. It must never show up in what the CLI writes. It's lowercase, so
# it would pass as a step name if the CLI ever echoed argv.
CLI_SENTINEL = "sentinel-7f3a9c-ssn"

# Unit tests of the dispatcher. Each plugs test steps into the CLI's steps
# table, the edge where real steps go, and runs the real CLI.
RSpec.describe Quaack::Enclave::CLI do
  let(:cli_class) { Quaack::Enclave::CLI }
  let(:step_class) { Quaack::Enclave::CLI::Step }
  let(:out) { StringIO.new }
  let(:base) { Dir.mktmpdir("quaack-cli") }
  let(:calls) { [] }

  after { FileUtils.rm_rf(base) }

  # A step that records what it was called with and returns messages.
  def recorder(messages = [{ type: :version, version: "ok" }])
    calls = self.calls
    ->(**inputs) { (calls << inputs) && messages }
  end

  def cli(steps, stdin: StringIO.new(""))
    cli_class.new(steps:, stdin:, out:, store_base: base)
  end

  def line(**fields) = "#{JSON.generate(fields.transform_keys(&:to_s))}\n"
  def error_line(step, rule) = line(type: "error", step:, rule:)

  describe "dispatch" do
    it "runs the named step and prints each message it returns as one egress line" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :version, version: "a" }, { type: :version, version: "b" }])) }

      expect(cli(steps).run(["echo"])).to eq(0)
      expect(out.string).to eq(line(type: "version", version: "a") + line(type: "version", version: "b"))
      expect(calls).to eq([{ input: nil, store: nil, options: {} }])
    end

    it "prints nothing for a message the egress function drops, and still succeeds" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :bogus, version: CLI_SENTINEL }, "not a hash"])) }

      expect(cli(steps).run(["echo"])).to eq(0)
      expect(out.string).to eq("")
    end

    it "drops a field that isn't on the whitelist" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :version, version: "1", value: CLI_SENTINEL }])) }

      expect(cli(steps).run(["echo"])).to eq(0)
      expect(out.string).to eq(line(type: "version", version: "1"))
    end

    it "prints only the error line when any message can't be written, not the ones before it" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :version, version: "1" },
                                                    { type: :version, version: Object.new }])) }

      expect(cli(steps).run(["echo"])).to eq(70)
      expect(out.string).to eq(error_line("echo", "internal_error"))
    end

    it "treats a step that doesn't return an Array as an internal error" do
      steps = { "echo" => step_class.new(handler: ->(**) { { type: :version, version: "1" } }) }

      expect(cli(steps).run(["echo"])).to eq(70)
      expect(out.string).to eq(error_line("echo", "internal_error"))
    end

    it "sends a step's error as its rule and SQLSTATE only, never its message" do
      error = Class.new(StandardError) do
        def rule = :volatile_function
        def sqlstate = "42883"
      end
      steps = { "echo" => step_class.new(handler: ->(**) { raise error, CLI_SENTINEL }) }

      expect(cli(steps).run(["echo"])).to eq(70)
      expect(out.string).to eq(line(type: "error", step: "echo", rule: "volatile_function", sqlstate: "42883"))
    end

    it "refuses an unknown subcommand, or none, as usage, without echoing it" do
      steps = { "echo" => step_class.new(handler: recorder) }

      [[CLI_SENTINEL], [], ["--echo"], [CLI_SENTINEL, "echo"]].each do |argv|
        out.truncate(0) && out.rewind
        expect(cli(steps).run(argv)).to eq(64)
        expect(out.string).to eq(error_line("cli", "usage")), "argv #{argv.inspect}"
      end
      expect(calls).to eq([])
    end

    it "maps --version to the version step" do
      expect(cli(cli_class::STEPS).run(["--version"])).to eq(0)
      expect(out.string).to eq(line(type: "version", version: Quaack::Enclave::VERSION))
    end
  end

  describe "options" do
    let(:steps) { { "echo" => step_class.new(handler: recorder, options: { "server" => :value, "keep" => :flag }) } }

    it "passes the options the step declares, as given" do
      expect(cli(steps).run(["echo", "--keep", "--server", CLI_SENTINEL])).to eq(0)
      expect(calls).to eq([{ input: nil, store: nil, options: { "keep" => true, "server" => CLI_SENTINEL } }])
    end

    it "refuses an unknown, repeated, or valueless option, or a bare argument, as usage" do
      [["--#{CLI_SENTINEL}"], %w[--keep --keep], %w[--server a --server b], ["--server"], [CLI_SENTINEL],
       ["--keep", CLI_SENTINEL], ["--run", "20260923T221500Z-0a1b2c3d"]].each do |args|
        out.truncate(0) && out.rewind
        expect(cli(steps).run(["echo", *args])).to eq(64), "args #{args.inspect}"
        expect(out.string).to eq(error_line("echo", "usage")), "args #{args.inspect}"
      end
      expect(calls).to eq([])
    end
  end

  describe "the run" do
    let(:steps) { { "echo" => step_class.new(handler: recorder, run: true) } }

    it "opens the run named by --run and passes its Store" do
      store = Quaack::Enclave::Store.create(base:)

      expect(cli(steps).run(["echo", "--run", store.run_id])).to eq(0)
      expect(calls.size).to eq(1)
      expect(calls[0][:store]).to be_a(Quaack::Enclave::Store)
      expect(calls[0][:store].run_id).to eq(store.run_id)
      expect(calls[0][:store].path).to eq(store.path)
    end

    it "refuses a missing or malformed run ID as usage" do
      [[], ["--run"], ["--run", CLI_SENTINEL], ["--run", "../20260923T221500Z-0a1b2c3d"]].each do |args|
        out.truncate(0) && out.rewind
        expect(cli(steps).run(["echo", *args])).to eq(64), "args #{args.inspect}"
        expect(out.string).to eq(error_line("echo", "usage")), "args #{args.inspect}"
      end
      expect(calls).to eq([])
    end

    it "refuses a well-formed run ID with no usable run as bad_run" do
      expect(cli(steps).run(%w[echo --run 20260923T221500Z-0a1b2c3d])).to eq(64)
      expect(out.string).to eq(error_line("echo", "bad_run"))
      expect(calls).to eq([])
    end
  end

  describe "input" do
    let(:steps) { { "echo" => step_class.new(handler: recorder, input: true) } }

    it "passes the JSON object on stdin, parsed" do
      expect(cli(steps, stdin: StringIO.new('{"sql":"SELECT 1","n":[1,2.5,null]}')).run(["echo"])).to eq(0)
      expect(calls).to eq([{ input: { "sql" => "SELECT 1", "n" => [1, 2.5, nil] }, store: nil, options: {} }])
    end

    it "refuses stdin that isn't one JSON object as bad_input, without its text" do
      ["", "{", %({"a": "#{CLI_SENTINEL}"), %(["#{CLI_SENTINEL}"]), %("#{CLI_SENTINEL}"), "null",
       %({"a": "#{CLI_SENTINEL}\xff"}), %({"a": "#{CLI_SENTINEL}"} {"b": 1}),
       %({"a": NaN, "b": "#{CLI_SENTINEL}"})].each do |text|
        out.truncate(0) && out.rewind
        expect(cli(steps, stdin: StringIO.new(text.b)).run(["echo"])).to eq(64), "stdin #{text.inspect}"
        expect(out.string).to eq(error_line("echo", "bad_input")), "stdin #{text.inspect}"
      end
      expect(calls).to eq([])
    end

    # JSON doesn't count an empty innermost container toward its limit, so
    # each depth is tried with an empty one and with a full one.
    it "reads nesting up to PlainData::MAX_DEPTH and refuses deeper" do
      depth = Quaack::Enclave::PlainData::MAX_DEPTH
      nest = ->(levels, inner) { ('{"a":' * (levels - 1)) + inner + ("}" * (levels - 1)) }

      [nest.(depth, "[]"), nest.(depth, "[1]")].each do |text|
        expect(cli(steps, stdin: StringIO.new(text)).run(["echo"])).to eq(0)
      end
      [nest.(depth + 1, "[]"), nest.(depth + 1, "[1]")].each do |text|
        out.truncate(0) && out.rewind
        expect(cli(steps, stdin: StringIO.new(text)).run(["echo"])).to eq(64)
        expect(out.string).to eq(error_line("echo", "bad_input"))
      end
      expect(calls.size).to eq(2)
    end

    it "reads up to Input::MAX_BYTES and refuses more as input_too_large" do
      max = cli_class::Input::MAX_BYTES
      expect(max).to eq(64 * 1024 * 1024)

      fits = "{#{" " * (max - 2)}}"
      expect(cli(steps, stdin: StringIO.new(fits)).run(["echo"])).to eq(0)
      expect(calls).to eq([{ input: {}, store: nil, options: {} }])

      out.truncate(0) && out.rewind
      expect(cli(steps, stdin: StringIO.new("#{fits} ")).run(["echo"])).to eq(64)
      expect(out.string).to eq(error_line("echo", "input_too_large"))
      expect(calls.size).to eq(1)
    end

    it "never reads stdin for a step that takes no input" do
      stdin = Object.new
      def stdin.read(*) = raise("read stdin")
      steps = { "echo" => step_class.new(handler: recorder) }

      expect(cli(steps, stdin:).run(["echo"])).to eq(0)
      expect(out.string).to eq(line(type: "version", version: "ok"))
    end

    it "raises a bad_input Refused with no cause and none of the input in its message" do
      error = begin
        cli_class::Input.read(StringIO.new(%({"a": "#{CLI_SENTINEL}")))
      rescue cli_class::Refused => e
        e
      end

      expect(error.rule).to eq("bad_input")
      expect(error.cause).to be_nil
      expect(error.message).not_to include(CLI_SENTINEL)
    end
  end

  describe "a write that fails partway" do
    # Writes the first few bytes of its first write, then raises, as a
    # write cut short would. Later writes go through.
    let(:flaky) do
      Class.new(StringIO) do
        def write(text)
          return super unless @failed.nil?

          @failed = true
          super(text[0, 5])
          raise IOError, "cut short"
        end
      end.new
    end

    it "starts the error line on a line of its own" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :version, version: "1" }])) }

      expect(cli_class.new(steps:, stdin: StringIO.new, out: flaky, store_base: base).run(["echo"])).to eq(70)
      expect(flaky.string).to eq(%({"typ\n#{error_line("echo", "internal_error")}))
    end
  end
end
