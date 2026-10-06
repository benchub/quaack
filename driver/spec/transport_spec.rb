# frozen_string_literal: true

require "json"
require "tmpdir"
require "quaack/driver/transport"

# The driver's side of the link to the enclave script. Most of these run the
# real enclave/exe/quaacks, or CLI.main with a test step, through the local
# transport. The rest stand in for the enclave script with a raw command, to
# print what the real one can't, such as a cut-off line.
RSpec.describe Quaack::Driver::Transport do
  let(:local) { Quaack::Driver::Transport::Local }
  let(:dir) { Dir.mktmpdir("quaack-driver-transport") }
  let(:sentinel) { "sentinel-7c31a9-ssn" }

  after { FileUtils.rm_rf(dir) }

  # A timeout well short of the default, so a bug that leaves a call
  # waiting fails the spec rather than hanging it.
  let(:timeout) { 60 }

  def probe(body, **step) = local.new(command: EnclaveCommands.probe(dir, body, **step), timeout:)
  def raw(source) = local.new(command: EnclaveCommands.raw(source), timeout:)

  # The file descriptors this process has open.
  # The file descriptors this process has open, after collecting any IO
  # an earlier spec left for the garbage collector to close.
  def open_fds = Dir.children("/dev/fd").size

  # Runs the block with the garbage collector off, after one collection,
  # so an IO some code leaked stays open for open_fds to count, and an IO
  # an earlier spec leaked can't be closed partway through.
  def without_gc
    GC.start
    GC.disable
    yield
  ensure
    GC.enable
  end

  # The EnclaveError that calling transport raises.
  def failure(transport, subcommand = "probe", **)
    transport.call(subcommand, **)
  rescue Quaack::Driver::EnclaveError => e
    e
  else
    raise "expected an EnclaveError, but the call succeeded"
  end

  describe "a run that succeeds" do
    it "returns the messages of the real quaacks version step, without the done line" do
      result = local.new(command: EnclaveCommands.quaacks, timeout:).call("version")

      expect(result.messages).to eq([{ "type" => "version", "version" => EnclaveCommands.enclave_version }])
    end
  end

  describe "arguments" do
    # A step that declares some options, and returns the argv it got.
    let(:echo) do
      probe("[{ type: :version, version: JSON.generate(ARGV) }]",
            options: { "query" => :value, "captured-at" => :value, "flag" => :flag })
    end

    def argv_of(result) = JSON.parse(result.messages.first.fetch("version"))

    it "passes each arg as --name value, or --name alone for true, in order" do
      result = echo.call("probe", args: { query: "SELECT 1 -- x", "captured-at": "--run", "flag" => true })

      expect(argv_of(result)).to eq(["probe", "--query", "SELECT 1 -- x", "--captured-at", "--run", "--flag"])
    end

    it "refuses a subcommand or an option name the CLI can't take, before running anything" do
      marker = File.join(dir, "ran")
      never = local.new(command: EnclaveCommands.raw("File.write(#{marker.inspect}, '')"))
      ["", "Version", "-x", "--version", "a b", "../x", "x=y", nil].each do |subcommand|
        expect { never.call(subcommand) }.to raise_error(ArgumentError), "for #{subcommand.inspect}"
      end
      ["", "Query", "-x", "--x", "a b", "x=y", "a_b", "1x", 1, nil].each do |name|
        expect { never.call("probe", args: { name => "v" }) }.to raise_error(ArgumentError), "for #{name.inspect}"
      end
      expect(File.exist?(marker)).to be(false)
    end

    it "refuses a value that isn't a String or true, or holds a NUL" do
      [nil, false, 1, :x, ["a"], "a\0b"].each do |value|
        expect { echo.call("probe", args: { query: value }) }.to raise_error(ArgumentError), "for #{value.inspect}"
      end
    end

    it "refuses a value that isn't valid UTF-8, and a name in an encoding that isn't ASCII-compatible" do
      ["a".encode("UTF-16LE"), "caf\xE9".b, "caf\xE9".dup.force_encoding("UTF-8"),
       "é".encode("ISO-8859-1")].each do |value|
        expect { echo.call("probe", args: { query: value }) }.to raise_error(ArgumentError), "for #{value.inspect}"
      end
      expect { echo.call("probe".encode("UTF-16LE")) }.to raise_error(ArgumentError)
      expect { echo.call("probe", args: { "query".encode("UTF-16LE") => "x" }) }.to raise_error(ArgumentError)
      expect(argv_of(echo.call("probe", args: { query: "é ✓".encode("UTF-8"), "captured-at": "x".b })))
        .to eq(["probe", "--query", "é ✓", "--captured-at", "x"])
    end

    it "takes names up to 63 characters, as the CLI does, and refuses longer ones" do
      error = failure(echo, "probe", args: { "a#{"b" * 62}" => "v" })

      expect(error.rule).to eq("usage")
      expect { echo.call("a#{"b" * 63}") }.to raise_error(ArgumentError)
      expect { echo.call("probe", args: { "a#{"b" * 63}" => "v" }) }.to raise_error(ArgumentError)
    end

    it "refuses args that aren't a Hash" do
      [[%w[query x]], nil, "query"].each do |args|
        expect { echo.call("probe", args:) }.to raise_error(ArgumentError), "for #{args.inspect}"
      end
    end

    it "takes argv up to MAX_ARGV_BYTES in all, and refuses more, since larger input belongs on stdin" do
      max = Quaack::Driver::Transport::Base::MAX_ARGV_BYTES
      # probe, --query, and the value, each with its NUL.
      fits = "x" * (max - "probe".bytesize - "--query".bytesize - 3)

      expect(max).to eq(64 * 1024)
      expect(argv_of(echo.call("probe", args: { query: fits })).last.bytesize).to eq(fits.bytesize)
      expect { echo.call("probe", args: { query: "#{fits}x" }) }.to raise_error(ArgumentError)
    end
  end

  describe "making a transport" do
    it "refuses a command that isn't a non-empty Array of Strings" do
      [[], "quaacks", [nil], ["ruby", 1], nil, [""]].each do |command|
        expect { local.new(command:) }.to raise_error(ArgumentError), "for #{command.inspect}"
      end
    end

    it "keeps its own copy of the command" do
      command = EnclaveCommands.quaacks
      transport = local.new(command:, timeout:)
      command.replace(["false"])

      expect(transport.call("version").messages.map { it["type"] }).to eq(["version"])
    end

    it "fails as not_started when the command can't be run" do
      error = failure(local.new(command: [File.join(dir, "missing")], timeout:))

      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["not_started", nil, nil, nil])
      expect([error.usage?, error.step_failed?, error.killed?]).to eq([false, false, false])
      expect(error.message).to eq("quaacks probe failed: not_started")
    end

    it "never lets the run's stderr reach the driver's" do
      step = raw(%($stderr.write("#{sentinel}"); STDERR.flush; print %({"type":"done"}\\n)))
      log = File.join(dir, "stderr")
      # STDERR, not $stderr: it owns file descriptor 2, which a child inherits.
      stderr = STDERR # rubocop:disable Style/GlobalStdStream
      saved = stderr.dup
      begin
        stderr.reopen(log, "w")
        step.call("probe")
      ensure
        stderr.reopen(saved)
      end

      expect(File.read(log)).not_to include(sentinel)
    end
  end

  describe "errors raised inside a rescue" do
    # A caller that calls the transport while handling an error of its own.
    def inside_rescue
      raise "outer #{sentinel}"
    rescue RuntimeError
      begin
        yield
      rescue StandardError => e
        e
      end
    end

    it "never takes the caller's error as its cause" do
      errors = [
        inside_rescue { probe("raise 'x'").call("probe") },
        inside_rescue { raw("print 1").call("probe") },
        inside_rescue { raw(%(print %({"type":"x"}\\n{"type":"done"}\\n))).call("probe") },
        inside_rescue { local.new(command: EnclaveCommands.raw("sleep 30"), timeout: 0.2).call("probe") },
        inside_rescue { local.new(command: [File.join(dir, "missing")]).call("probe") },
        inside_rescue { raw("").call("Bad") },
        inside_rescue { raw("").call("probe", input: []) },
        inside_rescue { local.new(command: []) },
        inside_rescue { local.new(command: ["x"], timeout: 0) }
      ]

      expect(errors.map(&:class)).to eq(([Quaack::Driver::EnclaveError] * 5) + ([ArgumentError] * 4))
      expect(errors.map(&:cause)).to all(be_nil)
      errors.each { expect(it.full_message(highlight: false)).not_to include(sentinel) }
    end
  end

  describe "input on stdin" do
    it "sends input as one JSON document, which the step gets back exactly" do
      input = { "query" => %(SELECT 'é', "x" /* y */\n), "n" => [1, 2.5, nil, true, false], "deep" => { "a" => {} },
                "text" => "\\u0041   \t" }
      step = probe("[{ type: :version, version: JSON.generate(inputs[:input]) }]", input: true)

      expect(JSON.parse(step.call("probe", input:).messages.first["version"])).to eq(input)
    end

    it "writes it with JSON.generate, so Symbol keys arrive as Strings" do
      step = probe("[{ type: :version, version: JSON.generate(inputs[:input]) }]", input: true)

      expect(JSON.parse(step.call("probe", input: { a: { b: :c } }).messages.first["version"]))
        .to eq({ "a" => { "b" => "c" } })
    end

    it "sends nothing on stdin when there's no input" do
      step = probe("[{ type: :version, version: $stdin.read }]")

      expect(step.call("probe").messages).to eq([{ "type" => "version", "version" => "" }])
    end

    it "refuses input that isn't a Hash, or that JSON can't write" do
      step = probe("[]", input: true)
      [[], "x", 1, { "a" => Float::NAN }].each do |input|
        expect { step.call("probe", input:) }.to raise_error(ArgumentError), "for #{input.inspect}"
      end
    end

    it "goes on reading when the run closes its stdin before taking all its input" do
      step = raw(%(STDIN.close; sleep 0.5; print %({"type":"version","version":"1"}\\n{"type":"done"}\\n)))

      expect(step.call("probe", input: { "a" => "x" * (8 * 1024 * 1024) }).messages)
        .to eq([{ "type" => "version", "version" => "1" }])
    end

    it "doesn't hang when the step never reads a large input" do
      result = local.new(command: EnclaveCommands.quaacks, timeout:).call("version",
                                                                          input: { "a" => "x" * (8 * 1024 * 1024) })

      expect(result.messages.map { it["type"] }).to eq(["version"])
    end
  end

  describe "limits" do
    def elapsed
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      yield
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    end

    # Whether a process with pid is still running.
    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    end

    # Whether pid, or with a negative pid its whole process group, ends
    # within two seconds. A killed grandchild's parent was the child, so once
    # the child is gone, init reaps it.
    def gone_soon?(pid)
      20.times do
        return true unless alive?(pid)

        sleep 0.1
      end
      false
    end

    # The pid comes from the spawn, not from a pid file the child writes,
    # which a child killed while still starting under load may not have
    # written yet. The run starts a grandchild, and the child leads its own
    # process group, so signal 0 to -pid proves the kill reached the whole
    # group, not just the child. The child writes the grandchild's pid only
    # once it has started it, so a missing file says the kill came first,
    # and the group check would prove nothing.
    it "kills a run that takes longer than its timeout, and its process group, and says so" do
      pids = []
      allow(Open3).to receive(:popen2).and_wrap_original do |original, *args, **opts|
        original.call(*args, **opts).tap { pids << it.last.pid }
      end
      ready = File.join(dir, "grandchild")
      source = %(pid = Process.spawn("sleep", "30"); File.write(#{"#{ready}.new".inspect}, pid.to_s); ) +
               %(File.rename(#{"#{ready}.new".inspect}, #{ready.inspect}); sleep 30)
      step = local.new(command: EnclaveCommands.raw(source), timeout: 2)
      error = nil

      # The timeout, plus the moment SIGTERM takes, with room for a loaded
      # machine, and far short of the 30s sleep.
      expect(elapsed { error = failure(step) }).to be < 10
      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["timeout", nil, nil, "TERM"])
      expect(error.message).to eq("quaacks probe failed: timeout (signal TERM)")
      expect(File.exist?(ready)).to be(true), "the grandchild never started before the timeout, so this proves nothing"
      expect(pids.size).to eq(1)
      expect([gone_soon?(Integer(File.read(ready))), gone_soon?(pids.first), gone_soon?(-pids.first)])
        .to eq([true, true, true])
    ensure
      # If the kill missed the group, don't leave the grandchild running.
      # Once its parent has gone, init reaps it.
      pids&.each do |pid|
        Process.kill("KILL", -pid)
      rescue Errno::ESRCH
        nil
      end
    end

    it "kills the run when the driver is interrupted while waiting for it, as by a Ctrl-C" do
      pid_file = File.join(dir, "pid")
      step = local.new(command: EnclaveCommands.raw("File.write(#{pid_file.inspect}, Process.pid.to_s); sleep 30"))
      caller = Thread.new { step.call("probe") }
      caller.report_on_exception = false
      Thread.pass until File.exist?(pid_file) && !File.empty?(pid_file)
      caller.raise(Interrupt)

      expect { caller.join }.to raise_error(Interrupt)
      expect(alive?(Integer(File.read(pid_file)))).to be(false)
    end

    # A grandchild that keeps the child's stdin open, and never reads it,
    # could leave a write of a large input blocked after the child ends.
    # The call returns once the child has, and leaves no thread or pipe
    # behind.
    it "returns once the run ends, even if something it started still holds stdin" do
      grandchild = "exec 3<&0; sleep 8 <&3 >/dev/null 2>&1 & printf '{\"type\":\"done\"}\\n'; exit 0"
      step = local.new(command: ["sh", "-c", grandchild], timeout: 5)
      input = { "a" => "x" * (16 * 1024 * 1024) }
      threads = Thread.list.size
      result = nil
      took = nil
      fds_before, fds_after = without_gc do
        before = open_fds
        took = elapsed { result = step.call("probe", input:) }
        [before, open_fds]
      end

      expect(took).to be < 4
      expect(result.messages).to eq([])
      expect([Thread.list.size, fds_after]).to eq([threads, fds_before])
    end

    # The timeout is long enough that the child has installed its TERM trap
    # before SIGTERM arrives, even when Ruby starts slowly under load. With a
    # short one, a slow start let SIGTERM kill it, and the test flaked.
    it "kills a run that ignores SIGTERM with SIGKILL" do
      step = local.new(command: EnclaveCommands.raw('trap("TERM") {}; sleep 60'), timeout: 5)
      error = nil

      expect(elapsed { error = failure(step) }).to be < 30
      expect([error.rule, error.signal]).to eq(%w[timeout KILL])
    end

    it "times out a run that closes its stdout and keeps going" do
      step = local.new(command: EnclaveCommands.raw("STDOUT.reopen(File::NULL); sleep 30"), timeout: 0.5)
      error = nil

      expect(elapsed { error = failure(step) }).to be < 10
      expect(error.rule).to eq("timeout")
    end

    it "kills a run that prints more than max_output_bytes, and says so" do
      step = local.new(command: EnclaveCommands.raw('print "x" * 5000; $stdout.flush; sleep 30'),
                       max_output_bytes: 1000)
      error = nil

      expect(elapsed { error = failure(step) }).to be < 10
      expect([error.rule, error.signal]).to eq(%w[output_too_large TERM])
    end

    it "reads a run that prints exactly max_output_bytes" do
      line = %({"type":"version","version":"1"}\n{"type":"done"}\n)
      step = local.new(command: EnclaveCommands.raw("print #{line.inspect}"), max_output_bytes: line.bytesize)

      expect(step.call("probe").messages).to eq([{ "type" => "version", "version" => "1" }])
    end

    it "has defaults generous enough for any step, and refuses a timeout or cap that isn't positive" do
      expect(Quaack::Driver::Transport::Base::DEFAULT_TIMEOUT).to eq(3600)
      expect(Quaack::Driver::Transport::Base::MAX_OUTPUT_BYTES).to eq(64 * 1024 * 1024)
      [0, -1, nil, "1"].each do |bad|
        expect { local.new(command: ["true"], timeout: bad) }.to raise_error(ArgumentError), "timeout #{bad.inspect}"
        expect { local.new(command: ["true"], max_output_bytes: bad) }
          .to raise_error(ArgumentError), "max_output_bytes #{bad.inspect}"
      end
    end
  end

  describe "a run that fails" do
    # A step error with its own rule and SQLSTATE, and a message holding a
    # sentinel, which must never reach the driver.
    let(:step_error) do
      <<~RUBY
        error = RuntimeError.new("#{sentinel}")
        error.define_singleton_method(:rule) { "unique_violation" }
        error.define_singleton_method(:sqlstate) { "23505" }
        raise error
      RUBY
    end

    it "raises an EnclaveError with the error line's step, rule, and SQLSTATE, and the exit status" do
      error = failure(probe(step_error))

      expect([error.subcommand, error.step, error.rule, error.sqlstate]).to eq(%w[probe probe unique_violation 23505])
      expect([error.exit_status, error.signal]).to eq([70, nil])
      expect([error.usage?, error.step_failed?, error.killed?]).to eq([false, true, false])
      expect(error.message).to eq("quaacks probe failed: unique_violation (step probe, SQLSTATE 23505, exit 70)")
    end

    it "carries only the error line's fields, never the step's error message" do
      error = failure(probe(step_error))

      expect(error.message).not_to include(sentinel)
      expect(error.full_message(highlight: false)).not_to include(sentinel)
      expect(error.cause).to be_nil
    end

    it "treats the CLI refusing the call as usage, exit 64" do
      error = failure(local.new(command: EnclaveCommands.quaacks, timeout:), "version", args: { "bogus" => "x" })

      expect([error.step, error.rule, error.sqlstate, error.exit_status]).to eq(["version", "usage", nil, 64])
      expect([error.usage?, error.step_failed?, error.killed?]).to eq([true, false, false])
      expect(error.message).to eq("quaacks version failed: usage (step version, exit 64)")
    end

    it "treats a death by a signal as killed, with the error line the enclave wrote before it died" do
      error = failure(probe('Process.kill("TERM", Process.pid); sleep 10'))

      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["internal_error", "probe", nil, "TERM"])
      expect([error.usage?, error.step_failed?, error.killed?]).to eq([false, false, true])
      expect(error.message).to eq("quaacks probe failed: internal_error (step probe, signal TERM)")
    end

    it "treats a death by SIGKILL, which leaves no error line, as incomplete and killed" do
      error = failure(probe('Process.kill("KILL", Process.pid); sleep 10'))

      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["incomplete", nil, nil, "KILL"])
      expect(error.killed?).to be(true)
      expect(error.message).to eq("quaacks probe failed: incomplete (signal KILL)")
    end

    it "treats a run that exits 0 without its done line, as after exit!(0), as incomplete" do
      error = failure(probe("exit!(0)"))

      expect([error.rule, error.step, error.exit_status, error.signal]).to eq(["incomplete", nil, 0, nil])
      expect(error.message).to eq("quaacks probe failed: incomplete (exit 0)")
    end

    it "discards the lines before an error line" do
      error = failure(raw(<<~'RUBY'))
        print %({"type":"version","version":"1"}\n{"type":"done"}\n{"type":"error","step":"probe","rule":"flush_failed"}\n)
        exit 70
      RUBY

      expect([error.rule, error.exit_status]).to eq(["flush_failed", 70])
    end

    it "takes the first error line when there are several" do
      error = failure(raw(<<~'RUBY'))
        print %({"type":"error","step":"probe","rule":"first"}\n{"type":"error","step":"cli","rule":"second"}\n)
        exit 70
      RUBY

      expect([error.step, error.rule]).to eq(%w[probe first])
    end

    it "treats a run that ends with its done line but exits nonzero, with no error line, as incomplete" do
      error = failure(raw(%(print %({"type":"version","version":"1"}\\n{"type":"done"}\\n); exit 3)))

      expect([error.rule, error.exit_status, error.signal]).to eq(["incomplete", 3, nil])
    end

    it "treats a run that ends with its done line but dies by a signal, with no error line, as incomplete" do
      error = failure(raw(%(print %({"type":"done"}\\n); $stdout.flush; Process.kill("KILL", Process.pid))))

      expect([error.rule, error.exit_status, error.signal]).to eq(["incomplete", nil, "KILL"])
    end
  end

  describe "reading the lines" do
    it "skips blank lines and lines that aren't JSON" do
      result = raw(<<~'RUBY').call("probe")
        print %(\n  \n{"type":"version",\nnot json\nnot json // or /* this */\n{"type":"version","version":"1"}\n\t\n{"type":"done"}\n\n \t\n)
      RUBY

      expect(result.messages).to eq([{ "type" => "version", "version" => "1" }])
    end

    it "fails a run whose error line follows a blank line and a cut-off line" do
      error = failure(raw(<<~'RUBY'))
        print %({"type":"version","version":"1"}\n\n{"type":"column_stats","table":"t","col\n{"type":"error","step":"probe","rule":"internal_error"}\n)
        exit 70
      RUBY

      expect([error.step, error.rule, error.exit_status]).to eq(["probe", "internal_error", 70])
    end

    it "treats a run whose last non-blank line isn't the done line as incomplete, even if that line isn't JSON" do
      [%({"type":"done"}\n{"type":"version","version":"1"}\n), %({"type":"done"}\nnot json\n),
       %({"type":"done"}\n{"type":"do), %({"type":"done"}\n{"type":"ver\xC3\n).b].each do |out|
        error = failure(raw("print #{out.inspect}"))

        expect([error.rule, error.exit_status]).to eq(["incomplete", 0]), "for #{out.inspect}"
      end
    end
  end

  # A long step, such as index-build, sends progress lines while it works, and the
  # driver hands each to the call's block as it arrives, not once the run
  # has ended. Only Protocol::PROGRESS types reach the block.
  describe "progress as it arrives" do
    let(:go) { File.join(dir, "go") }
    let(:progress_line) { %({"type":"index_build_progress","index":1,"total":2,"ddl":"CREATE INDEX x"}) }

    # A run that prints line, then waits for the go file before it ends.
    def waiting(line, timeout: 10)
      local.new(command: EnclaveCommands.raw(<<~RUBY), timeout:)
        $stdout.sync = true
        print #{"#{line}\n".inspect}
        sleep 0.01 until File.exist?(#{go.inspect})
        print %({"type":"done"}\\n)
      RUBY
    end

    it "hands each progress message to the block while the run is still going, and leaves it out of the result" do
      seen = []
      result = waiting(progress_line).call("probe") do |message|
        seen << message
        File.write(go, "")
      end

      expect(seen).to eq([{ "type" => "index_build_progress", "index" => 1, "total" => 2, "ddl" => "CREATE INDEX x" }])
      expect(result.messages).to eq([])
    end

    it "hands the block nothing but progress messages the whitelist allows" do
      File.write(go, "")
      seen = []
      waiting(%({"type":"version","version":"1"})).call("probe") { seen << it }
      planted = waiting(%({"type":"index_build_progress","index":1,"#{sentinel}":"#{sentinel}"}))

      expect { planted.call("probe") { seen << it } }
        .to raise_error(Quaack::Driver::EnclaveError) { expect(it.rule).to eq("unexpected_output") }
      expect(seen).to eq([])
    end

    it "reads a run with progress lines the same way when the call has no block" do
      File.write(go, "")

      expect(waiting(progress_line).call("probe").messages).to eq([])
    end
  end

  # The enclave's egress function already sends only what
  # Protocol::WHITELIST allows. The driver checks again, so a version
  # mismatch between the two sides shows up as a refusal, not a message the
  # driver half understands.
  describe "checking each message against the whitelist" do
    def refusal(line)
      failure(raw("print #{"#{line}\n{\"type\":\"done\"}\n".inspect}"))
    end

    it "refuses a run with a field that isn't on the whitelist, and doesn't carry the field or its value" do
      error = refusal(%({"type":"version","version":"1","secret_#{sentinel}":"#{sentinel}"}))

      expect([error.rule, error.step, error.exit_status]).to eq(["unexpected_output", nil, 0])
      expect(error.message).to eq("quaacks probe failed: unexpected_output (exit 0)")
      expect(error.full_message(highlight: false)).not_to include(sentinel)
    end

    it "refuses a message of a type that isn't on the whitelist, or with no type" do
      [%({"type":"#{sentinel}"}), %({"type":"rows","rows":["#{sentinel}"]}), %({"version":"1"}),
       %({"type":null}), %({"type":["version"]})].each do |line|
        error = refusal(line)

        expect(error.rule).to eq("unexpected_output"), "for #{line}"
        expect(error.full_message(highlight: false)).not_to include(sentinel)
      end
    end

    it "refuses JSON that isn't an object" do
      ['"version"', "[]", "12", "null", "true"].each do |line|
        expect(refusal(line).rule).to eq("unexpected_output"), "for #{line}"
      end
    end

    it "refuses a done line with a field, or a done line that isn't the last line" do
      expect(refusal(%({"type":"done","version":"1"})).rule).to eq("unexpected_output")
      expect(refusal(%({"type":"done"}\n{"type":"version","version":"1"})).rule).to eq("unexpected_output")
    end

    it "refuses a run whose last line is a done line with a field, rather than calling it incomplete" do
      error = failure(raw("print #{%({"type":"version","version":"1"}\n{"type":"done","version":"1"}\n).inspect}"))

      expect([error.rule, error.exit_status]).to eq(["unexpected_output", 0])
    end

    # The shapes the enclave's ErrorFilter gives an error line's fields.
    # The driver can't load the enclave, so its copies are pinned here: to
    # the enclave's source text, and at their edges.
    it "checks the error line's fields with the enclave ErrorFilter's own patterns" do
      source = File.read(File.join(REPO_ROOT, "enclave", "lib", "quaack", "enclave", "error_filter.rb"))
      fields = Quaack::Driver::Transport::ErrorFields
      { "RULE" => fields::RULE, "STEP" => fields::STEP, "SQLSTATE" => fields::SQLSTATE,
        "FUNCTION" => fields::FUNCTION, "IDENTIFIER" => fields::IDENTIFIER, "TYPE" => fields::TYPE,
        "BACKEND_START" => fields::BACKEND_START }.each do |name, pattern|
        enclave = source[%r{^\s*#{name} = /(.+)/$}, 1]

        expect(pattern.source).to eq(enclave), "#{name} differs from the enclave's #{enclave.inspect}"
      end
    end

    it "keeps an error line's fields only at the shapes' edges, and drops them just past" do
      fields = lambda do |step, rule, sqlstate|
        error = refusal(JSON.generate({ "type" => "error", "step" => step, "rule" => rule, "sqlstate" => sqlstate }))
        [error.step, error.rule, error.sqlstate]
      end
      step63 = "5a-#{"b" * 60}"
      rule63 = "a#{"_" * 62}"

      expect(fields.call(step63, rule63, "0A000")).to eq([step63, rule63, "0A000"])
      expect(fields.call("#{step63}c", "#{rule63}b", "23505")).to eq([nil, "unexpected_output", "23505"])
      expect(fields.call("-a", "1a", "2350")).to eq([nil, "unexpected_output", nil])
      expect(fields.call("_a", "_a", "235050")).to eq([nil, "unexpected_output", nil])
      expect(fields.call("a", "a", "2350a")).to eq(%w[a a] + [nil])
    end

    # Egress sends a burndown only if Protocol::Burndown.valid? passes, so
    # the driver checks the same.
    it "reads a burndown that Protocol::Burndown.valid? passes, and refuses one it doesn't" do
      good = %({"type":"burndown","stages":{},"totals":{"queries":3}})
      result = raw("print #{"#{good}\n{\"type\":\"done\"}\n".inspect}").call("probe")

      expect(result.messages).to eq([{ "type" => "burndown", "stages" => {}, "totals" => { "queries" => 3 } }])
      [%({"type":"burndown","stages":{},"totals":{"queries":"#{sentinel}"}}),
       %({"type":"burndown","stages":{"#{sentinel}":{}},"totals":{}}), %({"type":"burndown","totals":{}}),
       %({"type":"burndown","stages":{}})].each do |line|
        error = refusal(line)

        expect(error.rule).to eq("unexpected_output"), "for #{line}"
        expect(error.full_message(highlight: false)).not_to include(sentinel)
      end
    end

    # Egress sends a report only if its plans pass Protocol::PlanNodes.valid?,
    # so the driver checks the same.
    it "reads a report whose plans Protocol::PlanNodes.valid? passes, and refuses one whose plans it doesn't" do
      node = %({"node":"Seq Scan","relation":"public.t","index":null,"est_rows":5,"actual_rows":5.5,) +
             %("selectivity":0.05,"depth":0,"shared_hit_blocks":12,"shared_read_blocks":null)
      good = %({"type":"report","original_plan":[#{node}}],"rewrites":[{"plan":null},{"plan":[#{node}}]}]})
      result = raw("print #{"#{good}\n{\"type\":\"done\"}\n".inspect}").call("probe")

      expect(result.messages.map { it.values_at("type", "original_plan") })
        .to eq([["report", [{ "node" => "Seq Scan", "relation" => "public.t", "index" => nil, "est_rows" => 5,
                              "actual_rows" => 5.5, "selectivity" => 0.05, "depth" => 0,
                              "shared_hit_blocks" => 12, "shared_read_blocks" => nil }]]])
      [%({"type":"report","original_plan":[#{node},"filter":"#{sentinel}"}],"rewrites":[]}),
       %({"type":"report","original_plan":[#{node}}],"rewrites":[{"plan":[#{node},"#{sentinel}":1}]}]}),
       %({"type":"report","original_plan":[#{node.sub('"depth":0', '"depth":"0"')}}],"rewrites":[]}),
       %({"type":"report","original_plan":[#{node.sub("12", %("#{sentinel}"))}}],"rewrites":[]}),
       %({"type":"report","original_plan":[#{node.sub("null", %({"#{sentinel}":1}))}}],"rewrites":[]}),
       %({"type":"report","original_plan":[#{node.sub("12", "12.0")}}],"rewrites":[]}),
       %({"type":"report","original_plan":[],"rewrites":[{"plan":[#{node.sub("null", %(["#{sentinel}"]))}}]}]}),
       %({"type":"report","original_plan":[],"rewrites":["#{sentinel}"]}),
       %({"type":"report","rewrites":[]}), %({"type":"report","original_plan":[]})].each do |line|
        error = refusal(line)

        expect(error.rule).to eq("unexpected_output"), "for #{line}"
        expect(error.full_message(highlight: false)).not_to include(sentinel)
      end
    end

    it "refuses a message that repeats a key" do
      expect(refusal(%({"type":"version","version":"1","version":"2"})).rule).to eq("unexpected_output")
      expect(refusal(%({"type":"burndown","stages":{"a":1,"a":2},"totals":{}})).rule).to eq("unexpected_output")
    end

    it "refuses a message nested deeper than MAX_NESTING, and reads one nested exactly that deep" do
      limit = Quaack::Driver::Transport::Reply::MAX_NESTING
      # The limit egress writes each line under, JSON.generate's default.
      expect(limit).to eq(JSON::State.new.max_nesting)
      # The message object is one level, and each Array inside it one more.
      # JSON doesn't count an empty innermost Array, so this one holds a 1.
      deep = ->(levels) { %({"type":"column_stats","mcv_freqs":#{"[" * (levels - 1)}1#{"]" * (levels - 1)}}) }

      expect(refusal(deep.call(limit + 1)).rule).to eq("unexpected_output")
      expect(raw("print #{"#{deep.call(limit)}\n{\"type\":\"done\"}\n".inspect}").call("probe").messages.size).to eq(1)
    end

    # The laptop may run the driver outside Bundler, with Ruby 3.4's default
    # json (2.9.1), which takes the last of a repeated key where the
    # bundle's json refuses it. So this reads the same lines under both.
    it "reads the same way under Ruby's default json as under the bundle's" do
      script = <<~'RUBY'
        require "json"
        require "rbconfig"
        require "quaack/driver/transport/reply"
        _, status = Process.wait2(Process.spawn(RbConfig.ruby, "-e", "exit 0"))
        done = %({"type":"done"}\n)
        results = JSON.parse(ARGV.first).map do |line|
          Quaack::Driver::Transport::Reply.parse("#{line}\n#{done}", status, subcommand: "probe")
        rescue Quaack::Driver::EnclaveError => e
          e.rule
        end
        puts JSON.generate(results, allow_nan: true)
        puts $LOADED_FEATURES.grep(%r{/json\.rb\z}).first
      RUBY
      cases = { %({"type":"version","version":"1","version":"2"}) => "unexpected_output",
                %({"type":"burndown","stages":{"a":{"b":{"c":1,"c":2}}},"totals":{}}) => "unexpected_output",
                %({"type":"version","version":"1"}) => [{ "type" => "version", "version" => "1" }],
                %({"type":"version","vers) => [],
                # JSON.generate never writes a comment, an unknown escape, or
                # a number too big for a Float, and the two versions read
                # them differently, so they're refused on both.
                %({"type":"version","version":"1" /* x */}) => "unexpected_output",
                %({"type":"version","version":"1"} // x) => "unexpected_output",
                %( {"type":"version",/*c*/"version":"1"}) => "unexpected_output",
                %({"type":"version","version":"a\\q"}) => "unexpected_output",
                %({"type":"version","version":"\\x41"}) => "unexpected_output",
                %({"type":"version","version":1e999999}) => "unexpected_output",
                %({"type":"column_stats","mcv_freqs":[0.5,[-1e999]]}) => "unexpected_output",
                # A slash or comment marker inside a string is just text.
                %({"type":"version","version":"a/b//c /* d */ \\" \\\\ \\/ \\u0041"}) =>
                  [{ "type" => "version", "version" => %(a/b//c /* d */ " \\ / A) }],
                # A line cut off inside an escape is still just cut off.
                %({"type":"version","version":"a\\) => [],
                # Every escape JSON.generate writes, as egress would write a
                # multi-line query or plan, reads as a message.
                JSON.generate({ "type" => "version", "version" => "a\b\f\n\r\t\u0001\"\\/é" }) =>
                  [{ "type" => "version", "version" => "a\b\f\n\r\t\u0001\"\\/é" }] }
      paths = ["-I", File.join(GEM_ROOT, "lib"), "-I", File.join(REPO_ROOT, "protocol", "lib")]
      default = Bundler.with_unbundled_env do
        run_ruby("--disable-gems", *paths, "-e", script, JSON.generate(cases.keys, ascii_only: true))
      end
      bundled = run_ruby(*paths, "-e", script, JSON.generate(cases.keys, ascii_only: true))

      # The lines go over argv as ASCII, and come back as UTF-8, whatever
      # the locale says.
      { default => true, bundled => false }.each do |(out, err, status), stdlib|
        expect(status).to be_success, "stderr was #{err}"
        results, json = out.dup.force_encoding(Encoding::UTF_8).lines(chomp: true)
        expect(File.realpath(json).start_with?(File.realpath(RbConfig::CONFIG["rubylibdir"]))).to be(stdlib)
        expect(JSON.parse(results, allow_nan: true)).to eq(cases.values), "under #{json}"
      end
    end

    it "skips a line that isn't valid UTF-8, as it would a cut-off line" do
      # A version whose value is one byte, 0xC3, the start of a character.
      line = %({"type":"version","version":"\\xC3"}\\n{"type":"done"}\\n)
      result = raw("print \"#{line.gsub('"', '\\"')}\"").call("probe")

      expect(result.messages).to eq([])
    end

    it "fails with the error line's rule when a run has a refused line and an error line" do
      error = failure(raw(<<~RUBY))
        print %({"type":"version","secret":"#{sentinel}"}\\n{"type":"error","step":"probe","rule":"bad_input"}\\n)
        exit 64
      RUBY

      expect([error.rule, error.exit_status]).to eq(["bad_input", 64])
    end

    it "takes only an error line's shaped step, rule, and SQLSTATE" do
      error = refusal(%({"type":"error","step":"#{sentinel} x","rule":"#{sentinel} y","sqlstate":"#{sentinel}",) +
                      %("message":"#{sentinel}"}))

      expect([error.step, error.rule, error.sqlstate]).to eq([nil, "unexpected_output", nil])
      expect(error.full_message(highlight: false)).not_to include(sentinel)
    end

    it "shows a volatile_function refusal's qualified function name to the operator" do
      error = refusal(%({"type":"error","step":"volatility","rule":"volatile_function","function":"pg_catalog.random"}))

      expect(error.function).to eq("pg_catalog.random")
      expect(error.message).to include("function pg_catalog.random")
    end

    {
      "missing" => "no such file on the jump server",
      "symlink" => "path is a symlink on the jump server",
      "not_regular_file" => "not a regular file on the jump server",
      "permission_denied" => "permission denied on the jump server"
    }.each do |reason, text|
      %w[query_unreadable plan_unreadable].each do |rule|
        it "tells the operator #{rule} with reason #{reason} as #{text.inspect}" do
          error = refusal(%({"type":"error","step":"intake","rule":"#{rule}","reason":"#{reason}"}))

          expect(error.reason).to eq(reason)
          expect(error.rule_with_note).to eq("#{rule}: #{text}")
          expect(error.message).to eq("quaacks probe failed: #{rule} (step intake, reason #{text}, exit 0)")
        end
      end
    end

    it "drops an intake unreadable reason that is not one fixed cause" do
      error = refusal(%({"type":"error","rule":"query_unreadable","reason":"missing SENTINEL"}))

      expect(error.reason).to be_nil
      expect(error.message).to eq("quaacks probe failed: query_unreadable (exit 0)")
      expect(error.full_message(highlight: false)).not_to include("SENTINEL")
    end

    it "drops a reason on any rule but intake unreadable refusals" do
      error = refusal(%({"type":"error","rule":"bad_config","reason":"missing"}))

      expect(error.reason).to be_nil
    end

    it "drops a function field that isn't one plain qualified name" do
      error = refusal(%({"type":"error","rule":"volatile_function","function":"pg_catalog.random #{sentinel}"}))

      expect(error.function).to be_nil
      expect(error.full_message(highlight: false)).not_to include(sentinel)
    end

    %w[unsupported_type domain_check].each do |rule|
      it "shows the table, column, and type a #{rule} refusal names" do
        column = { "table" => "public.courses", "column" => "tags", "type" => "character varying(255)[]" }
        error = refusal(%({"type":"error","step":"scenarios","rule":"#{rule}","column":#{JSON.generate(column)}}))

        expect(error.column).to eq(column)
        expect(error.rule_with_note).to eq("#{rule}: public.courses.tags (character varying(255)[])")
        expect(error.message).to eq("quaacks probe failed: #{rule} (step scenarios, " \
                                    "column public.courses.tags (character varying(255)[]), exit 0)")
      end
    end

    column_good = { "table" => "public.t", "column" => "c", "type" => "int4range" }
    [
      ["a sentinel for a table", column_good.merge("table" => "SENTINEL")],
      ["a sentinel after a table", column_good.merge("table" => "public.t SENTINEL")],
      ["a sentinel for a column", column_good.merge("column" => "c SENTINEL")],
      ["a sentinel for a type", column_good.merge("type" => "int4range'SENTINEL'")],
      ["a sentinel on a line after a type", column_good.merge("type" => "int4range\nSENTINEL")],
      ["a value beside the type", column_good.merge("value" => "SENTINEL")],
      ["a missing type", column_good.except("type")],
      ["its keys in another order", column_good.slice("column", "table", "type")],
      ["an Integer type", column_good.merge("type" => 1)],
      ["a String", "SENTINEL"]
    ].each do |label, column|
      it "drops a column with #{label}" do
        error = refusal(%({"type":"error","rule":"unsupported_type","column":#{JSON.generate(column)}}))

        expect(error.column).to be_nil
        expect(error.rule_with_note).to eq("unsupported_type")
        expect(error.message).to eq("quaacks probe failed: unsupported_type (exit 0)")
        expect(error.full_message(highlight: false)).not_to include("SENTINEL")
      end
    end

    it "drops a column on any rule but unsupported_type and domain_check" do
      error = refusal(%({"type":"error","rule":"unsatisfiable_check","column":#{JSON.generate(column_good)}}))

      expect(error.column).to be_nil
    end

    it "shows the tables of an fk_cycle refusal, in the order their foreign keys point" do
      cycle = %w[public.accounts billing.courses public.accounts]
      line = { type: "error", step: "counterexample-round", rule: "fk_cycle", cycle: }
      error = refusal(JSON.generate(line))

      expect(error.cycle).to eq(cycle)
      expect(error.rule_with_note).to eq("fk_cycle: public.accounts -> billing.courses -> public.accounts")
      expect(error.message).to eq("quaacks probe failed: fk_cycle (step counterexample-round, " \
                                  "cycle public.accounts -> billing.courses -> public.accounts, exit 0)")
    end

    [
      ["a sentinel table", %w[public.a SENTINEL public.a]],
      ["a sentinel after a table", ["public.a SENTINEL", "public.b", "public.a SENTINEL"]],
      ["an end that isn't its start", %w[public.a public.b public.c]],
      ["no second table", %w[public.a public.a]],
      ["more than 64 tables", [*Array.new(64) { "public.t#{it}" }, "public.t0"]],
      ["a table that isn't a String", [1, "public.b", 1]],
      ["a String", "SENTINEL"]
    ].each do |label, cycle|
      it "drops a cycle with #{label}" do
        error = refusal(%({"type":"error","rule":"fk_cycle","cycle":#{JSON.generate(cycle)}}))

        expect(error.cycle).to be_nil
        expect(error.rule_with_note).to eq("fk_cycle")
        expect(error.message).to eq("quaacks probe failed: fk_cycle (exit 0)")
        expect(error.full_message(highlight: false)).not_to include("SENTINEL")
      end
    end

    it "drops a cycle on any rule but fk_cycle" do
      error = refusal(%({"type":"error","rule":"complex_check","cycle":["public.a","public.b","public.a"]}))

      expect(error.cycle).to be_nil
      expect(error.message).to eq("quaacks probe failed: complex_check (exit 0)")
    end

    it "shows the pids and start times of the other clients a run_server_other_clients failure names" do
      clients = %([{"pid":1234,"backend_start":"2026-09-29T16:01:02Z"},) +
                %({"pid":5678,"backend_start":"2026-09-29T17:00:00Z"}])
      error = refusal(%({"type":"error","step":"run-server","rule":"run_server_other_clients","clients":#{clients}}))

      expect(error.clients).to eq([{ "pid" => 1234, "backend_start" => "2026-09-29T16:01:02Z" },
                                   { "pid" => 5678, "backend_start" => "2026-09-29T17:00:00Z" }])
      expect(error.message).to eq("quaacks probe failed: run_server_other_clients (step run-server, " \
                                  "clients pid 1234 started 2026-09-29T16:01:02Z, " \
                                  "pid 5678 started 2026-09-29T17:00:00Z, exit 0)")
    end

    good = "2026-09-29T16:01:02Z"

    it "keeps twenty clients" do
      clients = Array.new(20) { { "pid" => it + 1, "backend_start" => good } }
      error = refusal(%({"type":"error","rule":"run_server_other_clients","clients":#{JSON.generate(clients)}}))

      expect(error.clients).to eq(clients)
      expect(error.message).to include("pid 20 started #{good}, exit 0)")
    end

    [
      ["an application_name beside the pid", %([{"pid":1,"backend_start":"#{good}","application_name":"SENTINEL"}])],
      ["a sentinel for a start time", %([{"pid":1,"backend_start":"SENTINEL"}])],
      ["a sentinel before a start time", %([{"pid":1,"backend_start":"SENTINEL #{good}"}])],
      ["a sentinel after a start time", %([{"pid":1,"backend_start":"#{good} SENTINEL"}])],
      ["a sentinel on a line before a start time", %([{"pid":1,"backend_start":"SENTINEL\\n#{good}"}])],
      ["a sentinel on a line after a start time", %([{"pid":1,"backend_start":"#{good}\\nSENTINEL"}])],
      ["a newline after a start time", %([{"pid":1,"backend_start":"#{good}\\n"}])],
      ["a String pid", %([{"pid":"1","backend_start":"#{good}"}])],
      ["a zero pid", %([{"pid":0,"backend_start":"#{good}"}])],
      ["a Float pid", %([{"pid":1.0,"backend_start":"#{good}"}])],
      ["a missing start time", %([{"pid":1}])],
      ["its keys in reverse order", %([{"backend_start":"#{good}","pid":1}])],
      ["a good entry and a sentinel", %([{"pid":1,"backend_start":"#{good}"},"SENTINEL"])],
      ["an empty Array", "[]"],
      ["twenty-one entries", JSON.generate(Array.new(21) { { "pid" => it + 1, "backend_start" => good } })],
      ["a String", %("SENTINEL")]
    ].each do |label, clients|
      it "drops clients with #{label}" do
        error = refusal(%({"type":"error","rule":"run_server_other_clients","clients":#{clients}}))

        expect(error.clients).to be_nil
        expect(error.message).to eq("quaacks probe failed: run_server_other_clients (exit 0)")
        expect(error.full_message(highlight: false)).not_to include("SENTINEL")
      end
    end

    it "drops clients on any rule but run_server_other_clients" do
      clients = %([{"pid":1,"backend_start":"#{good}"}])
      error = refusal(%({"type":"error","rule":"run_server_guc_mismatch","clients":#{clients}}))

      expect(error.clients).to be_nil
    end

    it "drops an error line's field that starts with a valid value and goes on past it" do
      error = refusal(%({"type":"error","step":"probe #{sentinel}","rule":"usage #{sentinel}",) +
                      %("sqlstate":"23505#{sentinel}"}))

      expect([error.step, error.rule, error.sqlstate]).to eq([nil, "unexpected_output", nil])
      expect(error.full_message(highlight: false)).not_to include(sentinel)
    end

    it "drops an error line's field that isn't a String, even one that would read as valid" do
      error = refusal(%({"type":"error","step":5,"rule":true,"sqlstate":23505}))

      expect([error.step, error.rule, error.sqlstate]).to eq([nil, "unexpected_output", nil])
      expect(error.message).to eq("quaacks probe failed: unexpected_output (exit 0)")
    end
  end
end
