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

  # Task 20261008-43: a gateway can echo a key with any of its characters
  # percent-encoded, the unreserved ones (letters, digits, _ . ~ -) too.
  describe "a key echoed with unreserved characters percent-encoded" do
    let(:key) { "sk-SENTINEL.key~value_0123" }

    def encode_all(text, upper: true)
      text.each_char.map { |char| format(upper ? "%%%02X" : "%%%02x", char.ord) }.join
    end

    it "scrubs a long key encoded in whole, in either case of hex" do
      secrets = described_class.secrets(nil, [key])

      [true, false].each do |upper|
        echoed = "bad key #{encode_all(key, upper:)} given"
        expect(described_class.scrub(echoed, secrets)).to eq("bad key [key] given")
      end
    end

    it "scrubs a long key encoded in part, with the rest as written" do
      secrets = described_class.secrets(nil, [key])
      echoed = "bad key sk%2DSENTINEL%2Ekey%7Evalue%5F0123 given"

      expect(described_class.scrub(echoed, secrets)).to eq("bad key [key] given")
    end

    it "scrubs a short key encoded as a whole token" do
      secrets = described_class.secrets(nil, ["SHORT-k_1"])

      expect(described_class.scrub("bad SHORT%2Dk%5F1 given", secrets)).to eq("bad [key] given")
      expect(described_class.scrub("bad %53%48%4f%52%54%2dk%5f%31 given", secrets)).to eq("bad [key] given")
    end

    it "leaves a short key's encoding inside a longer token alone, as it does the plain key" do
      secrets = described_class.secrets(nil, ["SHORT-k_1"])

      expect(described_class.scrub("xSHORT%2Dk%5F1", secrets)).to eq("xSHORT%2Dk%5F1")
    end

    it "catches a planted encoded sentinel: with no secret to scrub, it stays in the text" do
      echoed = "bad key #{encode_all(key)} given"

      expect(described_class.scrub(echoed, [])).to include(encode_all(key))
      expect(described_class.scrub(echoed, described_class.secrets(nil, [key]))).not_to include("%")
    end
  end
end
