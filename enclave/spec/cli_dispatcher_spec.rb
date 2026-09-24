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

# Input the json versions differ on: Ruby 3.4's default json (2.9.1), which
# the jump server loads, takes the last of a repeated key and skips
# comments, while the bundle's json (3.0.2) refuses both. Input refuses
# them on both, and the --disable-gems spec below checks that under 2.9.1.
INPUT_REFUSED_ON_EVERY_JSON = [
  %({"a": 1, "a": "#{CLI_SENTINEL}"}), %({"a": {"b": 1, "b": "#{CLI_SENTINEL}"}}),
  %({"a": [{"b": 1, "b": "#{CLI_SENTINEL}"}]}), %(/* #{CLI_SENTINEL} */ {"a": 1}),
  %({"a": /* #{CLI_SENTINEL} */ 1}), %({"a": 1 // #{CLI_SENTINEL}\n}), %({"a": 1}\n// #{CLI_SENTINEL}\n),
  # 2.9.1 keeps the character after an unknown escape; 3.0.2 refuses it.
  *%w[q x41 a ' 0 U0041].map { |escape| %({"a": "#{CLI_SENTINEL}\\#{escape}"}) },
  # Both read a number too big for a Float as Infinity.
  %({"a": 1e400, "b": "#{CLI_SENTINEL}"}), %({"a": [[-1e400]], "b": "#{CLI_SENTINEL}"}),
  %({"a": 1, "b": 1e400, "c": "#{CLI_SENTINEL}"}), %({"a": [1, [2, -1e400]], "b": "#{CLI_SENTINEL}"})
].freeze

# Input these must accept on every json version: a slash or comment marker
# inside a string isn't a comment.
INPUT_ACCEPTED_ON_EVERY_JSON = {
  %({"sql": "SELECT 1 /* hint */ -- x", "path": "a/b//c"}) =>
    { "sql" => "SELECT 1 /* hint */ -- x", "path" => "a/b//c" },
  %({"q": "a \\" /* not a comment */ \\\\", "b": "/"}) => { "q" => %(a " /* not a comment */ \\), "b" => "/" },
  %({"a": {"b": 1}, "c": {"b": 2}}) => { "a" => { "b" => 1 }, "c" => { "b" => 2 } },
  %({"a": "\\"\\\\\\/\\b\\f\\n\\r\\t\\u0041\\u00e9"}) => { "a" => %("\\/\b\f\n\r\tAé) },
  %({"a": 1e300, "b": -0.5e-400}) => { "a" => 1e300, "b" => -0.0 }
}.freeze

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
  # The line that ends every successful run, and no failed one.
  def done = line(type: "done")

  describe "dispatch" do
    it "runs the named step and prints each message it returns as one egress line" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :version, version: "a" },
                                                            { type: :version, version: "b" }])) }

      expect(cli(steps).run(["echo"])).to eq(0)
      expect(out.string).to eq(line(type: "version", version: "a") + line(type: "version", version: "b") + done)
      expect(calls).to eq([{ input: nil, store: nil, options: {} }])
    end

    it "prints nothing for a message the egress function drops, and still succeeds with its done line" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :bogus, version: CLI_SENTINEL }, "not a hash"])) }

      expect(cli(steps).run(["echo"])).to eq(0)
      expect(out.string).to eq(done)
    end

    it "drops a field that isn't on the whitelist" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :version, version: "1", value: CLI_SENTINEL }])) }

      expect(cli(steps).run(["echo"])).to eq(0)
      expect(out.string).to eq(line(type: "version", version: "1") + done)
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
      expect(out.string).to eq(line(type: "version", version: Quaack::Enclave::VERSION) + done)
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
       ["--keep", CLI_SENTINEL], ["--run", "20260923T221500Z-0a1b2c3d"], ["keep"], %w[server x]].each do |args|
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
      expect(calls[0][:options]).to eq({})
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

  # A step that starts a run (new_run: true), as intake does.
  describe "a new run" do
    def runs = Dir.children(base)

    it "creates a run under the store base and passes its Store" do
      steps = { "start" => step_class.new(handler: recorder, new_run: true) }

      expect(cli(steps).run(["start"])).to eq(0)
      expect(calls.size).to eq(1)
      store = calls[0][:store]
      expect(store).to be_a(Quaack::Enclave::Store)
      expect(runs).to eq([store.run_id])
      expect(Quaack::Enclave::Store.open(store.run_id, base:).path).to eq(store.path)
    end

    it "keeps what the step wrote when it succeeds" do
      handler = lambda do |store:, **|
        store.write("query", "SELECT 1")
        []
      end
      steps = { "start" => step_class.new(handler:, new_run: true) }

      expect(cli(steps).run(["start"])).to eq(0)
      expect(runs.size).to eq(1)
      expect(Quaack::Enclave::Store.open(runs[0], base:).read("query")).to eq("SELECT 1")
    end

    it "deletes the run, and what the step wrote to it, when the step fails" do
      handler = lambda do |store:, **|
        store.write("query", CLI_SENTINEL)
        raise ArgumentError, CLI_SENTINEL
      end
      steps = { "start" => step_class.new(handler:, new_run: true) }

      expect(cli(steps).run(["start"])).to eq(70)
      expect(out.string).to eq(error_line("start", "internal_error"))
      expect(runs).to eq([])
    end

    it "deletes the run when the step's options are refused" do
      steps = { "start" => step_class.new(handler: recorder, new_run: true, options: { "query" => :value }) }

      expect(cli(steps).run(%w[start --bogus])).to eq(64)
      expect(out.string).to eq(error_line("start", "usage"))
      expect(runs).to eq([])
    end

    it "deletes the run when a message can't be written" do
      steps = { "start" => step_class.new(handler: recorder([{ type: :version, version: Object.new }]),
                                          new_run: true) }

      expect(cli(steps).run(["start"])).to eq(70)
      expect(runs).to eq([])
    end

    it "deletes the run when writing the output fails, even after the done line went out" do
      flush_fails = Class.new(StringIO) { def flush = raise(IOError, "flush failed") }.new
      steps = { "start" => step_class.new(handler: recorder, new_run: true) }

      expect(cli_class.new(steps:, stdin: StringIO.new, out: flush_fails, store_base: base).run(["start"])).to eq(70)
      expect(runs).to eq([])
    end

    it "deletes the run when the process gets a signal during the step, and still dies by it" do
      steps = { "start" => step_class.new(handler: ->(**) { raise Interrupt }, new_run: true) }

      expect { cli(steps).run(["start"]) }.to raise_error(Interrupt)
      expect(runs).to eq([])
    end

    it "still sends the step's own rule when deleting the run fails" do
      failure = Class.new(StandardError) { def rule = "step_rule" }
      handler = lambda do |store:, **|
        FileUtils.rm_r(store.path)
        File.write(store.path, "not a directory")
        raise failure, CLI_SENTINEL
      end
      steps = { "start" => step_class.new(handler:, new_run: true) }

      expect(cli(steps).run(["start"])).to eq(70)
      expect(out.string).to eq(error_line("start", "step_rule"))
    end

    it "checks the arguments, required options, and stdin before it makes the run" do
      blocked = File.join(base, "file").tap { File.write(it, "") }
      steps = { "start" => step_class.new(handler: recorder, new_run: true, input: true,
                                          options: { "query" => :value }, required: ["query"]) }
      { %w[start --bogus] => ["{}", "usage"], %w[start] => ["{}", "usage"],
        %w[start --query q] => ["[]", "bad_input"] }.each do |argv, (stdin, rule)|
        out.truncate(0) && out.rewind
        cli = cli_class.new(steps:, stdin: StringIO.new(stdin), out:, store_base: File.join(blocked, "runs"))

        expect(cli.run(argv)).to eq(64), argv.inspect
        expect(out.string).to eq(error_line("start", rule)), argv.inspect
      end
      expect(calls).to eq([])
    end

    it "takes no --run" do
      steps = { "start" => step_class.new(handler: recorder, new_run: true) }

      expect(cli(steps).run(%w[start --run 20260923T221500Z-0a1b2c3d])).to eq(64)
      expect(out.string).to eq(error_line("start", "usage"))
      expect(calls).to eq([])
    end

    it "can't be combined with run: true" do
      expect { step_class.new(handler: recorder, new_run: true, run: true) }
        .to raise_error(ArgumentError, "a step can't both start a run and open one")
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
       %({"a": NaN, "b": "#{CLI_SENTINEL}"}), *INPUT_REFUSED_ON_EVERY_JSON].each do |text|
        out.truncate(0) && out.rewind
        expect(cli(steps, stdin: StringIO.new(text.b)).run(["echo"])).to eq(64), "stdin #{text.inspect}"
        expect(out.string).to eq(error_line("echo", "bad_input")), "stdin #{text.inspect}"
      end
      expect(calls).to eq([])
    end

    it "accepts comment markers and slashes inside strings, and a key repeated in different objects" do
      INPUT_ACCEPTED_ON_EVERY_JSON.each do |text, parsed|
        calls.clear
        expect(cli(steps, stdin: StringIO.new(text)).run(["echo"])).to eq(0), "stdin #{text.inspect}"
        expect(calls).to eq([{ input: parsed, store: nil, options: {} }])
      end
    end

    # The jump server runs outside Bundler, so it gets Ruby's default json,
    # not the bundle's.
    it "refuses and accepts the same input under Ruby's default json" do
      script = <<~RUBY
        require "json"
        require "stringio"
        require "quaack/enclave/cli/input"
        cli = Quaack::Enclave::CLI
        results = JSON.parse(ARGV[0]).map do |text|
          cli::Input.read(StringIO.new(text))
        rescue cli::Refused => e
          e.rule
        end
        puts JSON.generate(results)
        puts $LOADED_FEATURES.grep(%r{/json\\.rb\\z}).first
      RUBY
      cases = [*INPUT_REFUSED_ON_EVERY_JSON, *INPUT_ACCEPTED_ON_EVERY_JSON.keys]
      out, err, status = Bundler.with_unbundled_env do
        run_ruby("--disable-gems", "-I", File.join(GEM_ROOT, "lib"), "-e", script, JSON.generate(cases))
      end

      expect(status).to be_success, "stderr was #{err}"
      results, json = out.lines(chomp: true)
      expect(File.realpath(json)).to start_with(File.realpath(RbConfig::CONFIG["rubylibdir"]))
      expect(JSON.parse(results))
        .to eq([*["bad_input"] * INPUT_REFUSED_ON_EVERY_JSON.size, *INPUT_ACCEPTED_ON_EVERY_JSON.values])
    end

    # A regex that repeats over each character can keep a backtrack entry
    # per character, about 70 bytes each, so a 64 MB input once took 5 GB.
    # Each child builds one input of about 32 MB, of spaces or inside a
    # string, from a 64 KB chunk so building it leaves no bigger peak of its
    # own. It reports its peak RSS (getrusage's ru_maxrss: bytes on macOS,
    # KB on Linux) before and after parsing it. The peak before must hold
    # the input itself, so a reading that's always 0, such as the wrong
    # field of rusage, can't pass.
    it "parses big input in memory a small multiple of its size" do
      script = <<~RUBY
        require "fiddle"
        require "stringio"
        require "quaack/enclave/cli/input"
        getrusage = Fiddle::Function.new(Fiddle.dlopen(nil)["getrusage"], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP],
                                         Fiddle::TYPE_INT)
        usage = Fiddle::Pointer.malloc(256)
        peak = lambda do
          getrusage.call(0, usage)
          usage[32, 8].unpack1("q") * (RUBY_PLATFORM.include?("darwin") ? 1 : 1024)
        end
        size = 32 * 1024 * 1024
        chunk = ARGV[0] * (64 * 1024)
        text = String.new(ARGV[1], capacity: size + 16)
        (size / chunk.bytesize).times { text << chunk }
        text << ARGV[2]
        GC.start
        before = peak.call
        Quaack::Enclave::CLI::Input.parse(text)
        puts before, peak.call, size
      RUBY
      [[" ", "{", "}"], ["x", '{"a":"', '"}']].each do |filler, open, close|
        out, err, status = Bundler.with_unbundled_env do
          run_ruby("--disable-gems", "-I", File.join(GEM_ROOT, "lib"), "-e", script, filler, open, close)
        end

        expect(status).to be_success, "stderr was #{err}"
        before, after, size = out.lines.map { Integer(it) }
        expect(before).to be > size, "peak RSS before parsing was #{before >> 20} MB, less than the input"
        expect(after - before).to be < 6 * size,
                                  "#{filler.inspect}: peak RSS grew #{(after - before) >> 20} MB for #{size >> 20} MB"
      end
    end

    # JSON doesn't count an empty innermost container toward its limit, so
    # each depth is tried with an empty one and with a full one.
    it "reads nesting up to PlainData::MAX_DEPTH and refuses deeper" do
      depth = Quaack::Enclave::PlainData::MAX_DEPTH
      nest = ->(levels, inner) { ('{"a":' * (levels - 1)) + inner + ("}" * (levels - 1)) }

      [nest.call(depth, "[]"), nest.call(depth, "[1]")].each do |text|
        expect(cli(steps, stdin: StringIO.new(text)).run(["echo"])).to eq(0)
      end
      [nest.call(depth + 1, "[]"), nest.call(depth + 1, "[1]")].each do |text|
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
      expect(out.string).to eq(line(type: "version", version: "ok") + done)
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

    # Its first flush raises, after the write before it finished.
    let(:flush_fails) do
      Class.new(StringIO) do
        def flush
          return super unless @failed.nil?

          @failed = true
          raise IOError, "flush failed"
        end
      end.new
    end

    it "adds no blank line when the write before the error finished" do
      steps = { "echo" => step_class.new(handler: recorder([{ type: :version, version: "1" }])) }

      expect(cli_class.new(steps:, stdin: StringIO.new, out: flush_fails, store_base: base).run(["echo"])).to eq(70)
      expected = line(type: "version", version: "1") + done + error_line("echo", "internal_error")
      expect(flush_fails.string).to eq(expected)
    end
  end

  describe Quaack::Enclave::CLI::Output do
    let(:io) { StringIO.new }
    let(:output) { described_class.new(io) }

    it "starts a write on a new line after one that ended mid-line" do
      output.write("abc")
      output.write("x\n")

      expect(io.string).to eq("abc\nx\n")
    end

    it "adds nothing after a write that ended its line, or one that wrote nothing" do
      output.write("a\n")
      output.write("")
      output.write("b\n")

      expect(io.string).to eq("a\nb\n")
    end
  end
end
