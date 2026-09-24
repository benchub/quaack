# frozen_string_literal: true

require "json"
require "stringio"
require "quaack/enclave/error_filter"

# Stands in for a real production value. It must never show up in anything
# the error filter writes or returns.
ERROR_SENTINEL = "SENTINEL-4d71e0-customers.email"

# Stand-ins for the errors the filter gets.
module FilterFakes
  # An error that names its own rule and SQLSTATE, the way an enclave error can.
  class RuledError < StandardError
    attr_reader :rule, :sqlstate

    def initialize(message = ERROR_SENTINEL, rule: nil, sqlstate: nil)
      super(message)
      @rule = rule
      @sqlstate = sqlstate
    end
  end

  # An error whose every way of describing itself raises, with the sentinel in
  # what it raises. The filter must never ask it any of these.
  class LoudError < StandardError
    def rule = "loud_rule"

    %i[message to_s inspect full_message detailed_message backtrace backtrace_locations cause].each do |name|
      define_method(name) { |*| raise ERROR_SENTINEL }
    end
  end

  # Duck types a PG::Error, whose result holds the error fields.
  FakeResult = Struct.new(:sqlstate) do
    def error_field(code) = code == 67 ? sqlstate : ERROR_SENTINEL
  end

  class ResultError < StandardError
    attr_reader :result

    def initialize(result)
      super(ERROR_SENTINEL)
      @result = result
    end
  end
end

RSpec.describe Quaack::Enclave::ErrorFilter do
  let(:filter) { described_class }

  def line(**fields) = JSON.generate({ "type" => "error", **fields.transform_keys(&:to_s) })

  def recurse_forever = 1 + recurse_forever

  def raised
    yield
  rescue Exception => e # rubocop:disable Lint/RescueException
    e
  end

  it "is loaded by quaack/enclave" do
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", <<~RUBY)
      require "quaack/enclave"
      print Quaack::Enclave::ErrorFilter.to_egress(RuntimeError.new("x"), step: "3f")
    RUBY

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq(line(step: "3f", rule: "internal_error"))
  end

  describe ".to_egress" do
    it "sends the step, the error's rule, and its SQLSTATE, and nothing else" do
      error = FilterFakes::RuledError.new(rule: "unique_email", sqlstate: "23505")

      out = filter.to_egress(error, step: "3f")

      expect(out).to eq(line(step: "3f", rule: "unique_email", sqlstate: "23505"))
      expect(out).not_to include(ERROR_SENTINEL)
    end

    it "takes a rule given as a Symbol" do
      expect(filter.to_egress(FilterFakes::RuledError.new(rule: :bad_search_path), step: "3a"))
        .to eq(line(step: "3a", rule: "bad_search_path"))
    end

    it "takes steps named the way the README and the subcommands name them" do
      %w[3f 5a-1 10b intake qualify_relations].each do |step|
        expect(filter.to_egress(RuntimeError.new, step:)).to eq(line(step:, rule: "internal_error"))
      end
    end

    it "sends internal_error, and no SQLSTATE, for an error with neither" do
      out = filter.to_egress(RuntimeError.new("Key (email)=(#{ERROR_SENTINEL}) already exists."), step: "9b")

      expect(out).to eq(line(step: "9b", rule: "internal_error"))
    end

    it "never sends the cause chain, even when a cause has a rule and a SQLSTATE" do
      error = raised do
        raise FilterFakes::RuledError.new(rule: "cause_rule", sqlstate: "23505")
      rescue FilterFakes::RuledError
        raise "wrapped: #{ERROR_SENTINEL}"
      end
      expect(error.cause.message).to eq(ERROR_SENTINEL)

      expect(filter.to_egress(error, step: "3f")).to eq(line(step: "3f", rule: "internal_error"))
    end

    it "never asks the error for its message, backtrace, inspect, or cause" do
      out = filter.to_egress(FilterFakes::LoudError.new, step: "3f")

      expect(out).to eq(line(step: "3f", rule: "loud_rule"))
    end

    it "sends internal_error when the error's rule method raises" do
      error = FilterFakes::RuledError.new(sqlstate: "23505")
      def error.rule = raise(ERROR_SENTINEL)

      expect(filter.to_egress(error, step: "3f")).to eq(line(step: "3f", rule: "internal_error", sqlstate: "23505"))
    end

    it "sends internal_error for a rule that isn't a short lowercase identifier" do
      tricky = Class.new(String) { def to_s = ERROR_SENTINEL }
      [ERROR_SENTINEL, :"Unique-Violation", "unique_violation\n", "", "_rule", "9rule", "a" * 64,
       "rule\xFF".b, "rule".encode("UTF-16LE"), tricky.new("tricky_rule"), 42, nil, [:rule]].each do |rule|
        out = filter.to_egress(FilterFakes::RuledError.new(rule:), step: "3f")

        expect(out).to eq(line(step: "3f", rule: "internal_error")), "for rule #{rule.inspect}"
      end
    end

    it "takes a rule of up to 63 characters" do
      rule = "a" * 63

      expect(filter.to_egress(FilterFakes::RuledError.new(rule:), step: "3f")).to eq(line(step: "3f", rule:))
    end

    it "drops a SQLSTATE that isn't five digits or capital letters" do
      odd = Class.new(String) { def to_s = ERROR_SENTINEL }
      [ERROR_SENTINEL, "2350", "235055", "23505\n", "2350a", "2350\xFF".b, "23505".encode("UTF-16LE"), 23_505,
       :"23505", odd.new("23505"), nil]
        .each do |sqlstate|
        out = filter.to_egress(FilterFakes::RuledError.new(rule: "r", sqlstate:), step: "3f")

        expect(out).to eq(line(step: "3f", rule: "r")), "for sqlstate #{sqlstate.inspect}"
      end
    end

    it "reads the SQLSTATE from a PG-style error's result" do
      expect(filter.to_egress(FilterFakes::ResultError.new(FilterFakes::FakeResult.new("40P01")), step: "13"))
        .to eq(line(step: "13", rule: "internal_error", sqlstate: "40P01"))
    end

    it "drops a bad SQLSTATE from a PG-style error's result, or a result that isn't there" do
      results = [FilterFakes::FakeResult.new(ERROR_SENTINEL), FilterFakes::FakeResult.new(nil), nil, ERROR_SENTINEL]
      results.each do |result|
        out = filter.to_egress(FilterFakes::ResultError.new(result), step: "13")

        expect(out).to eq(line(step: "13", rule: "internal_error")), "for result #{result.inspect}"
      end
    end

    it "drops a step that isn't a short lowercase name" do
      [ERROR_SENTINEL, "3F", "", "-3f", "3f\n", "a" * 64, 3, nil].each do |step|
        out = filter.to_egress(RuntimeError.new, step:)

        expect(out).to eq(line(rule: "internal_error")), "for step #{step.inspect}"
      end
    end

    it "filters an Egress::Error that came from a real value" do
      error = raised { Quaack::Enclave::Egress.serialize(type: :error, rule: "#{ERROR_SENTINEL}\xFF".b) }
      expect(error).to be_a(Quaack::Enclave::Egress::Error)

      expect(filter.to_egress(error, step: "3f")).to eq(line(step: "3f", rule: "internal_error"))
    end

    it "filters an Egress::Error with the sentinel in its message" do
      error = Quaack::Enclave::Egress::Error.new(ERROR_SENTINEL)

      expect(filter.to_egress(error, step: "3f")).to eq(line(step: "3f", rule: "internal_error"))
    end

    describe "when the egress function fails" do
      it "has a fallback line that the egress function would send itself" do
        expect(described_class::FALLBACK).to eq(Quaack::Enclave::Egress.serialize(type: :error, rule: "internal_error"))
      end

      # The egress function never fails for the fields the filter checks, so
      # these fake it, to test the fallback that's there in case it ever does.
      it "sends the fallback line when the egress function returns nil" do
        allow(Quaack::Enclave::Egress).to receive(:serialize).and_return(nil)

        expect(filter.to_egress(FilterFakes::RuledError.new(rule: "r"), step: "3f")).to eq(described_class::FALLBACK)
      end

      it "sends the fallback line, and doesn't raise, when the egress function raises" do
        allow(Quaack::Enclave::Egress).to receive(:serialize).and_raise(Quaack::Enclave::Egress::Error, ERROR_SENTINEL)

        expect(filter.to_egress(FilterFakes::RuledError.new(rule: "r"), step: "3f")).to eq(described_class::FALLBACK)
      end
    end
  end

  describe ".guard" do
    let(:out) { StringIO.new }

    it "returns the block's value, and writes nothing, when the block succeeds" do
      result = nil
      expect { result = filter.guard(step: "3f", out:) { 0 } }.not_to output.to_stderr

      expect(result).to eq(0)
      expect(out.string).to eq("")
    end

    it "writes one filtered error line and returns a nonzero status for anything raised" do
      errors = {
        "an error" => -> { raise FilterFakes::RuledError.new(rule: "unique_email", sqlstate: "23505") },
        "a stack overflow" => -> { recurse_forever },
        "running out of memory" => -> { raise NoMemoryError, ERROR_SENTINEL },
        "a load error" => -> { require "quaack/enclave/#{ERROR_SENTINEL}" },
        "a script error" => -> { raise NotImplementedError, ERROR_SENTINEL },
        "an interrupt" => -> { raise Interrupt, ERROR_SENTINEL },
        "a signal" => -> { raise SignalException, "TERM" },
        "an egress error" => -> { raise Quaack::Enclave::Egress::Error, ERROR_SENTINEL },
        "a loud error" => -> { raise FilterFakes::LoudError }
      }
      errors.each do |name, block|
        out = StringIO.new
        status = nil

        expect { status = filter.guard(step: "3f", out:, &block) }.not_to output.to_stderr

        expect(status).to eq(described_class::EX_SOFTWARE), "for #{name}"
        expect(out.string.lines.size).to eq(1), "for #{name}"
        expect(JSON.parse(out.string)).to include("type" => "error", "step" => "3f"), "for #{name}"
        expect(out.string).not_to include(ERROR_SENTINEL), "for #{name}"
      end
    end

    it "fails with EX_SOFTWARE, which is nonzero" do
      status = filter.guard(step: "3f", out:) { raise ERROR_SENTINEL }

      expect(status).to eq(70)
    end

    it "writes what to_egress gives, as a line" do
      filter.guard(step: "3f", out:) { raise FilterFakes::RuledError.new(rule: "unique_email", sqlstate: "23505") }

      expect(out.string).to eq("#{line(step: "3f", rule: "unique_email", sqlstate: "23505")}\n")
    end

    it "lets exit pass, with its status" do
      expect { filter.guard(step: "3f", out:) { exit 3 } }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
      expect(out.string).to eq("")
    end

    it "still returns a nonzero status when it can't write the error line" do
      closed = StringIO.new.tap(&:close)
      status = nil

      expect { status = filter.guard(step: "3f", out: closed) { raise ERROR_SENTINEL } }.not_to output.to_stderr
      expect(status).to eq(described_class::EX_SOFTWARE)
    end
  end

  describe ".silence_stderr!" do
    # Every way a child process can reach stderr: $stderr, warn, the STDERR
    # constant, the raw file descriptor, a dying thread's report, and an
    # uncaught exception's backtrace.
    def loud_script
      <<~RUBY
        sentinel = #{ERROR_SENTINEL.dump}
        $stderr.puts "stderr " + sentinel
        warn "warn " + sentinel
        STDERR.syswrite "syswrite " + sentinel
        IO.new(2, autoclose: false).write "fd " + sentinel
        Thread.new { raise "thread " + sentinel }.join rescue nil
        $stdout.print "reached"
        raise "uncaught " + sentinel
      RUBY
    end

    # $stderr starts out as a copy of stderr, not the STDERR constant, so
    # silencing has to point $stderr back at STDERR too.
    def loud_child(silence:)
      silencing = silence ? "Quaack::Enclave::ErrorFilter.silence_stderr!" : ""
      run_ruby("-I", File.join(GEM_ROOT, "lib"), "-r", "quaack/enclave/error_filter", "-e",
               "$stderr = STDERR.dup\n#{silencing}\n#{loud_script}")
    end

    it "sees the sentinel on stderr without it, so the check works" do
      _out, err, _status = loud_child(silence: false)

      %w[stderr warn syswrite fd thread uncaught].each do |way|
        expect(err).to include("#{way} #{ERROR_SENTINEL}")
      end
    end

    it "keeps everything off stderr, however it's written" do
      out, err, status = loud_child(silence: true)

      expect(status).not_to be_success
      expect(err).to eq("")
      expect(out).to eq("reached")
    end
  end
end
