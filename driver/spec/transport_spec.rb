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

  def probe(body, **step) = local.new(command: EnclaveCommands.probe(dir, body, **step))
  def raw(source) = local.new(command: EnclaveCommands.raw(source))

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
      result = local.new(command: EnclaveCommands.quaacks).call("version")

      expect(result.messages).to eq([{ "type" => "version", "version" => EnclaveCommands.enclave_version }])
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
      error = failure(local.new(command: EnclaveCommands.quaacks), "version", args: { "bogus" => "x" })

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
        print %(\n  \n{"type":"version",\nnot json\n{"type":"version","version":"1"}\n\t\n{"type":"done"}\n\n \t\n)
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
       %({"type":"done"}\n{"type":"do)].each do |out|
        error = failure(raw("print #{out.inspect}"))

        expect([error.rule, error.exit_status]).to eq(["incomplete", 0]), "for #{out}"
      end
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
        puts JSON.generate(results)
        puts $LOADED_FEATURES.grep(%r{/json\.rb\z}).first
      RUBY
      cases = { %({"type":"version","version":"1","version":"2"}) => "unexpected_output",
                %({"type":"burndown","stages":{"a":{"b":{"c":1,"c":2}}},"totals":{}}) => "unexpected_output",
                %({"type":"version","version":"1"}) => [{ "type" => "version", "version" => "1" }],
                %({"type":"version","vers) => [] }
      out, err, status = Bundler.with_unbundled_env do
        run_ruby("--disable-gems", "-I", File.join(GEM_ROOT, "lib"), "-I", File.join(REPO_ROOT, "protocol", "lib"),
                 "-e", script, JSON.generate(cases.keys))
      end

      expect(status).to be_success, "stderr was #{err}"
      results, json = out.lines(chomp: true)
      expect(File.realpath(json)).to start_with(File.realpath(RbConfig::CONFIG["rubylibdir"]))
      expect(JSON.parse(results)).to eq(cases.values)
    end

    it "skips a line that isn't valid UTF-8, as it would a cut-off line" do
      result = raw(%(print "{\\"type\\":\\"version\\",\\"version\\":\\"\\xC3\\"}\\n{\\"type\\":\\"done\\"}\\n")).call("probe")

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
  end
end
