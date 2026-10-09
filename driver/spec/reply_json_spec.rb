# frozen_string_literal: true

require "quaack/driver/llm"

RSpec.describe Quaack::Driver::LLM::ReplyJSON do
  let(:schema) do
    { type: "object", properties: { ddl: { type: "array", items: { type: "string" } } }, required: ["ddl"] }
  end

  def error_for(text)
    described_class.parse(text, schema)
    raise "expected an LLM::Error"
  rescue Quaack::Driver::LLM::Error => e
    e.message
  end

  [
    ["braces", "Some {prose} with {braces {nested} } and } strays { "],
    ["braces and quotes", %(Say { "a {b} c" then { "odd } and {x "y" z} " ")],
    ["opened braces before an odd quote", "#{"{" * 8000} \"#{"x" * 1000}"]
  ].each do |name, unit|
    it "parses each { at most once on 16 KB of #{name} junk, and finishes quickly" do
      junk = (unit * 1000)[0, 16_384]
      allow(JSON).to receive(:parse).and_call_original

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(error_for(junk)).to end_with("the reply wasn't valid JSON")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(JSON).to have_received(:parse).at_most(junk.count("{") + 1).times
    end
  end

  it "finds the object after non-ASCII prose" do
    expect(described_class.parse(%(Café ☃: {"ddl": []}), schema)).to eq("ddl" => [])
  end

  it "finds an object that holds non-ASCII text" do
    expect(described_class.parse(%({"ddl": ["héllo ☃ 日本"]} tail), schema)).to eq("ddl" => ["héllo ☃ 日本"])
  end

  it "finds the object after a stray { and an odd quote in prose" do
    expect(described_class.parse(%(I'll use { as a "quote. Then {"ddl": []}), schema)).to eq("ddl" => [])
  end

  it "finds the object after a stray { whose odd quote hides a }" do
    expect(described_class.parse(%({ note: it's "odd } {"ddl": []}), schema)).to eq("ddl" => [])
  end

  it "finds the object when a stray { and two prose quotes swallow it into a span that won't parse" do
    text = %(Use {the "plan:\n```json\n{"ddl": ["x"]}\n```\nsee "notes} ok)
    expect(described_class.parse(text, schema)).to eq("ddl" => ["x"])
  end

  it "finds the fenced object after more prose braces than any fixed count of starts" do
    text = "#{"see {a} " * 33}\n```json\n{\"ddl\": [\"CREATE INDEX i ON t(a)\"]}\n```"

    expect(described_class.parse(text, schema)).to eq("ddl" => ["CREATE INDEX i ON t(a)"])
  end

  it "finds a 200-row fenced object after lines of SQL and code prose with braces" do
    prose = Array.new(20) do |i|
      "Line #{i}: WHERE a = ANY('{1,2}') and the template {x} uses \"quotes\" and } strays."
    end.join("\n")
    rows = Array.new(200) { |i| "CREATE INDEX i#{i} ON t(a#{i})" }
    text = "#{prose}\n```json\n#{JSON.generate("ddl" => rows)}\n```\nThat's all."

    expect(described_class.parse(text, schema)).to eq("ddl" => rows)
  end

  it "skips a braced string value holding braces and quotes" do
    text = 'Note {x}. {"ddl": ["SELECT \'{\\"}\' AS b"]}'

    expect(described_class.parse(text, schema)).to eq("ddl" => ["SELECT '{\"}' AS b"])
  end

  it "takes the outer object over a matching object nested inside it" do
    text = %(Here: {"ddl": ["outer"], "example": {"ddl": ["inner"]}} done)

    expect(described_class.parse(text, schema)).to eq("ddl" => ["outer"], "example" => { "ddl" => ["inner"] })
  end

  it "says prose whose braces hold no object wasn't valid JSON" do
    expect(error_for("Use {x} or {y}, then stop.")).to end_with("the reply wasn't valid JSON")
  end

  it "says a later object that parses but lacks a required key didn't match the schema" do
    expect(error_for('text {x} then {"other":[]}')).to end_with("the reply didn't match the schema")
  end

  it "says a reply cut off mid-object wasn't valid JSON, even when an inner object parses" do
    expect(error_for('{"ddl": [], "notes": {"a": 1}, "more": "cut')).to end_with("the reply wasn't valid JSON")
  end

  it "still says a whole object that lacks a required key didn't match the schema" do
    expect(error_for('Sure: {"other": []} done')).to end_with("the reply didn't match the schema")
  end
end

RSpec.describe Quaack::Driver::LLM::ReplyShape do
  it "requires a required key that has no type" do
    schema = { type: "object", properties: {}, required: ["note"] }

    expect(described_class.matches?({}, schema)).to be(false)
    expect(described_class.matches?({ "note" => 1 }, schema)).to be(true)
  end
end
