# frozen_string_literal: true

require "open3"
require "rbconfig"
require "quaack/protocol/burndown"

# The burndown's shared names. The enclave records stage counts under STAGES
# and the driver counts LLM calls under LLM_STEPS, so both sides use one list.
RSpec.describe Quaack::Protocol::Burndown do
  it "lists each stage of the README 15b tables once, as a frozen String" do
    expect(described_class::STAGES).to eq(%w[5a-1 5a-2 5a-3 5a-4 5a-5 5a-6 5a-7 6a 6b
                                             step7 step8 step9 step10 step11 step14])
    expect(described_class::STAGES).to be_frozen.and(all(be_frozen))
  end

  it "lists the driver steps that call an LLM, once each, as frozen Strings" do
    expect(described_class::LLM_STEPS).to eq(%w[5a-5 5a-6 6a step7 10a step11])
    expect(described_class::LLM_STEPS).to be_frozen.and(all(be_frozen))
  end

  it "takes a name only if it's a lowercase word of at most 63 characters" do
    name = described_class::NAME
    expect(%w[original duplicate generator_one rewrite_3].map { name.match?(it) }).to all(be(true))
    expect(["", "Duplicate", "3rd", "a-b", "a b", "a\n", "bob@x.com", "a" * 64].map { name.match?(it) })
      .to all(be(false))
    expect(name.match?("a" * 63)).to be(true)
  end

  describe ".valid?" do
    let(:record) do
      { "in" => 3, "added" => { "llm" => 2 }, "dropped" => { "duplicate" => 1 }, "set_aside" => 1, "out" => 3,
        "extra" => { "retries" => 4 } }
    end
    let(:totals) { { "hypothetical_explains" => 6 } }

    def valid?(stages, totals = self.totals) = described_class.valid?(stages:, totals:)

    def with_record(changed) = { "5a-3" => { "original" => changed } }

    it "takes stages and totals of counts, keyed by stage, search, field, and lowercase-word names" do
      expect(valid?({ "5a-3" => { "original" => record, "rewrite2" => record }, "step8" => {} })).to be(true)
      expect(valid?({}, {})).to be(true)
    end

    it "refuses a count that isn't an Integer of zero or more" do
      ["x", 1.0, nil, -1, [1], { "a" => 1 }].each do |bad|
        expect(valid?(with_record(record.merge("in" => bad, "out" => bad)))).to be(false), bad.inspect
        expect(valid?({}, { "fixture_loads" => bad })).to be(false), bad.inspect
        expect(valid?(with_record(record.merge("extra" => { "retries" => bad })))).to be(false), bad.inspect
      end
      expect(valid?(with_record(record.merge("in" => 2, "dropped" => { "duplicate" => -1 }, "out" => 4)))).to be(false)
    end

    it "refuses a name that isn't a lowercase-word String, as JSON reads one back" do
      ["bob@example.com", "Original", :original, 7, nil].each do |bad|
        expect(valid?({ "5a-3" => { bad => record } })).to be(false), bad.inspect
        expect(valid?(with_record(record.merge("dropped" => { bad => 0 })))).to be(false), bad.inspect
        expect(valid?({}, { bad => 1 })).to be(false), bad.inspect
      end
    end

    it "refuses a stage that isn't one of STAGES" do
      expect(valid?({ "orders.email" => {} })).to be(false)
      expect(valid?({ "5a-3": {} })).to be(false)
    end

    it "refuses a record with a field missing or added, or a breakdown that isn't a Hash" do
      expect(valid?(with_record(record.except("extra")))).to be(false)
      expect(valid?(with_record(record.merge("rows" => 1)))).to be(false)
      expect(valid?(with_record(record.merge("added" => [["llm", 2]])))).to be(false)
      expect(valid?(with_record("bob@example.com"))).to be(false)
    end

    it "refuses a record that mixes String and Symbol keys, without raising" do
      expect(valid?(with_record(record.except("extra").merge(extra: {})))).to be(false)
    end

    it "refuses a count of 10**12 or more, which is no real count" do
      expect(valid?({}, { "fixture_loads" => (10**12) - 1 })).to be(true)
      expect(valid?({}, { "fixture_loads" => 10**12 })).to be(false)
      expect(valid?(with_record(record.merge("in" => 10**15, "out" => 10**15)))).to be(false)
    end

    it "refuses a record that doesn't add up" do
      expect(valid?(with_record(record.merge("out" => 4)))).to be(false)
      expect(valid?(with_record(record.merge("set_aside" => 0)))).to be(false)
      expect(valid?(with_record(record.merge("added" => {})))).to be(false)
      expect(valid?(with_record(record.merge("dropped" => {})))).to be(false)
    end

    it "refuses stages or totals that aren't Hashes" do
      expect(valid?(nil)).to be(false)
      expect(valid?({}, nil)).to be(false)
      expect(valid?({ "5a-3" => "bob@example.com" })).to be(false)
      expect(valid?([["5a-3", {}]])).to be(false)
    end
  end

  it "is loaded by quaack/protocol" do
    lib = File.join(GEM_ROOT, "lib")
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "--disable-gems", "-I", lib,
                     "-e", 'require "quaack/protocol"; print Quaack::Protocol::Burndown::STAGES.size')
    end

    expect(status).to be_success, "stderr was #{err}"
    expect(Integer(out)).to eq(described_class::STAGES.size)
  end
end
