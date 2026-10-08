# frozen_string_literal: true

require "quaack/driver/llm"

# LLM::Error's reason, which the router's lines show (RouterLines), and how
# a blank one shows.
RSpec.describe Quaack::Driver::LLM::Error do
  describe "#naming" do
    it "names the provider in the message but keeps the adapter's reason as it was" do
      error = described_class.new("llm_unavailable", "the API answered 503 (sizes)", reason: "the API answered 503")

      named = error.naming("groq")
      expect(named.message).to eq("llm_unavailable: groq: the API answered 503 (sizes)")
      expect(named.rule).to eq("llm_unavailable")
      expect(named.reason).to eq("the API answered 503")
    end
  end
end

RSpec.describe Quaack::Driver::LLM::RouterLines do
  let(:blank) { Quaack::Driver::LLM::Error.new("llm_unavailable", "x", reason: " \n\t ") }

  it "shows only the rule for a reason that's blank" do
    expect(described_class.failed("llm_unavailable", " \n\t ")).to eq("llm_unavailable")
    expect(described_class.failed("llm_unavailable", nil)).to eq("llm_unavailable")
  end

  it "gives no parentheses in a line for a reason that's blank" do
    expect(described_class.line("groq", blank, "trying opus (llm-rewrites)", named: true))
      .to eq("groq is unavailable, so the rest of this run skips it; trying opus (llm-rewrites)")
  end
end
