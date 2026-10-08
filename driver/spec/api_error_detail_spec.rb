# frozen_string_literal: true

require "quaack/driver/llm/api_error_detail"

# The adapters' own examples of the detail are in
# support/anthropic_error_examples.rb. The settings refuse a base_url that
# can't be parsed, so no adapter reaches this case.
RSpec.describe Quaack::Driver::LLM::APIErrorDetail do
  it "still scrubs the adapter's own keys when base_url can't be parsed" do
    secrets = described_class.secrets("https://gateway.example.test/a%zz?key=SENTINEL-QUERY", ["SENTINEL-OWN-KEY"])

    expect(described_class.scrub("saw SENTINEL-OWN-KEY", secrets)).to eq("saw [key]")
  end
end
