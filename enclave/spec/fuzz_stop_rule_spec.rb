# frozen_string_literal: true

require "quaack/enclave/fuzz/stop_rule"

# The fuzz search's stop rule (task 20261012-2, the user's): at least the
# floor, then stop once the search has run twice as long as it took to find
# its last new coverage signature, never past the cap.
RSpec.describe Quaack::Enclave::Fuzz::StopRule do
  let(:now) { [0.0] }
  let(:clock) { -> { now.first } }

  def seconds_rule(floor: 30, cap: nil) = described_class.new(floor:, cap:, clock:)

  it "runs at least the floor, even with nothing new to find" do
    rule = seconds_rule
    rule.observe(:a)
    now[0] = 29.9
    expect(rule.stop?).to be(false)
    now[0] = 30.0
    expect(rule.stop?).to be(true)
  end

  it "past the floor, goes on until twice the time of the last new signature" do
    rule = seconds_rule
    now[0] = 20.0
    rule.observe(:a)
    now[0] = 25.0
    rule.observe(:b)
    now[0] = 49.9
    rule.observe(:a)
    expect(rule.stop?).to be(false)
    now[0] = 50.0
    expect(rule.stop?).to be(true)
  end

  it "counts only a signature it hasn't seen as new" do
    rule = seconds_rule
    now[0] = 10.0
    rule.observe(%w[x y])
    now[0] = 40.0
    rule.observe(%w[x y])
    expect(rule.stop?).to be(true)
  end

  it "never runs past the cap" do
    rule = seconds_rule(cap: 60)
    now[0] = 59.0
    rule.observe(:late)
    expect(rule.stop?).to be(false)
    now[0] = 60.0
    expect(rule.stop?).to be(true)
  end

  it "measures from when it was made, not from the clock's zero" do
    now[0] = 1000.0
    rule = seconds_rule
    now[0] = 1029.0
    expect(rule.stop?).to be(false)
    expect(rule.elapsed).to eq(29.0)
  end

  describe "counting trials instead of seconds" do
    it "is the same rule with each observed trial one unit, and a cap of ten floors" do
      rule = described_class.trials(10)
      9.times { |i| rule.observe(i.zero? ? :a : :seen) }
      expect(rule.stop?).to be(false)
      rule.observe(:seen)
      expect(rule.stop?).to be(true)
      expect(rule.trials).to eq(10)
    end

    it "goes on past the floor while new signatures keep coming, up to the cap" do
      rule = described_class.trials(10)
      100.times { |i| rule.observe(i) }
      expect(rule.stop?).to be(true)
      expect(rule.trials).to eq(100)
      rule = described_class.trials(10)
      15.times { |i| rule.observe(i) }
      expect(rule.stop?).to be(false)
    end
  end

  describe ".from_env" do
    it "is the user's rule by default: a 30-second floor on the monotonic clock, with no cap of its own" do
      rule = described_class.from_env({})
      expect(rule.floor).to eq(30)
      expect(rule.cap).to be_nil
      expect(rule.unit).to eq(:seconds)
    end

    it "counts trials when QUAACKS_FUZZ_TRIALS names a floor, for specs" do
      rule = described_class.from_env({ "QUAACKS_FUZZ_TRIALS" => "40" })
      expect([rule.floor, rule.cap, rule.unit]).to eq([40, 400, :trials])
    end

    it "refuses a QUAACKS_FUZZ_TRIALS that isn't a positive whole number" do
      ["0", "-3", "1.5", "lots", ""].each do |bad|
        expect { described_class.from_env({ "QUAACKS_FUZZ_TRIALS" => bad }) }
          .to raise_error(ArgumentError, /QUAACKS_FUZZ_TRIALS/)
      end
    end
  end
end
