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

  # Task 20261007-61: the scrub runs on an API's error, so it must never
  # raise one of its own, whose message could quote a secret.
  it "never raises, whatever bytes the text, keys, and base_url hold" do
    random = Random.new(20_261_007)
    encodings = [Encoding::UTF_8, Encoding::BINARY, Encoding::UTF_16LE, Encoding::UTF_7]
    fuzz = -> { random.bytes(random.rand(0..40)).force_encoding(encodings.sample(random:)) }
    escape = -> { Array.new(random.rand(1..6)) { format("%%%02X", random.rand(256)) }.join }

    failures = Array.new(400) do
      key = fuzz.call
      url = "https://gateway.example.test/SENTINELPATHKEY0123#{escape.call}/x?k=SENTINEL#{escape.call}"
      text = "#{fuzz.call.b} #{key.b} #{fuzz.call.b}".b.force_encoding(encodings.sample(random:))
      described_class.scrub(text, described_class.secrets(url, [key, fuzz.call, nil]))
      nil
    rescue StandardError => e
      "#{e.class}: #{e.message.b.inspect}"
    end

    expect(failures.compact).to eq([])
  end
end
