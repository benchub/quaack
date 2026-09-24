# frozen_string_literal: true

require "json"
require "quaack/enclave/egress"

# Stands in for a real production value. It must never show up in what
# Egress.serialize returns, or in anything it raises.
EGRESS_SENTINEL = "SENTINEL-8f3a2c-orders.email"

RSpec.describe Quaack::Enclave::Egress do
  let(:egress) { described_class }
  let(:whitelist) { Quaack::Protocol::WHITELIST }

  def parsed(message) = JSON.parse(egress.serialize(message))

  it "is loaded by quaack/enclave" do
    out, err, status = run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e",
                                'require "quaack/enclave"; print Quaack::Enclave::Egress.serialize(type: :error)')

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq('{"type":"error"}')
  end

  describe "the sentinel check itself" do
    it "sees the sentinel when it's in an allowed field" do
      out = egress.serialize(type: :error, step: "3f", rule: EGRESS_SENTINEL)

      expect(out).to include(EGRESS_SENTINEL)
    end
  end

  describe "a message of a whitelisted type" do
    it "keeps an error's allowed fields and drops the rest" do
      out = egress.serialize(type: :error, step: "3f", rule: "unique_violation", sqlstate: "23505",
                             message: "Key (email)=(#{EGRESS_SENTINEL}) already exists.",
                             detail: EGRESS_SENTINEL, backtrace: [EGRESS_SENTINEL])

      expect(JSON.parse(out)).to eq("type" => "error", "step" => "3f", "rule" => "unique_violation",
                                    "sqlstate" => "23505")
      expect(out).not_to include(EGRESS_SENTINEL)
    end

    it "keeps column_stats' allowed fields, values unchanged, and drops the rest" do
      out = egress.serialize(
        type: :column_stats, table: "public.orders", column: "status", n_distinct: 4, null_frac: 0.0,
        correlation: nil, mcv_freqs: [0.5, 0.25], low_card_values: %w[new paid],
        most_common_vals: [EGRESS_SENTINEL], histogram_bounds: [EGRESS_SENTINEL]
      )

      expect(JSON.parse(out)).to eq(
        "type" => "column_stats", "table" => "public.orders", "column" => "status", "n_distinct" => 4,
        "null_frac" => 0.0, "correlation" => nil, "mcv_freqs" => [0.5, 0.25], "low_card_values" => %w[new paid]
      )
      expect(out).not_to include(EGRESS_SENTINEL)
    end

    it "keeps every field on each type's list, and only those, for every type on the whitelist" do
      whitelist.each do |type, fields|
        message = fields.to_h { |f| [f, "value of #{f}"] }.merge(type: type, not_on_the_list: EGRESS_SENTINEL)
        out = egress.serialize(message)

        expect(JSON.parse(out)).to eq({ "type" => type.to_s, **fields.to_h { |f| [f.to_s, "value of #{f}"] } })
        expect(out).not_to include(EGRESS_SENTINEL)
      end
    end

    it "prints type first and then the fields in whitelist order, whatever order they came in" do
      out = egress.serialize(sqlstate: "23505", rule: "r", step: "s", type: :error)

      expect(out).to eq('{"type":"error","step":"s","rule":"r","sqlstate":"23505"}')
    end

    it "leaves out an allowed field the message doesn't have, rather than sending null" do
      expect(parsed(type: :error, step: "3f")).to eq("type" => "error", "step" => "3f")
    end

    it "sends an allowed field that's present but nil as null" do
      expect(parsed(type: :error, step: "3f", sqlstate: nil))
        .to eq("type" => "error", "step" => "3f", "sqlstate" => nil)
    end

    it "treats String keys and a String type the same as Symbols" do
      symbols = egress.serialize(type: :error, step: "3f", rule: "r", sqlstate: "23505", detail: EGRESS_SENTINEL)
      strings = egress.serialize("type" => "error", "step" => "3f", "rule" => "r", "sqlstate" => "23505",
                                 "detail" => EGRESS_SENTINEL)
      mixed = egress.serialize(:type => "error", "step" => "3f", :rule => "r", "sqlstate" => "23505",
                               "detail" => EGRESS_SENTINEL, :message => EGRESS_SENTINEL)

      expect(strings).to eq(symbols)
      expect(mixed).to eq(symbols)
      expect(JSON.parse(strings)).to eq("type" => "error", "step" => "3f", "rule" => "r", "sqlstate" => "23505")
    end

    it "drops keys that are neither Symbols nor Strings, even one whose to_s is a field name" do
      rule = Object.new
      def rule.to_s = "rule"
      out = egress.serialize(type: :error, step: "3f", 1 => EGRESS_SENTINEL, rule => EGRESS_SENTINEL)

      expect(JSON.parse(out)).to eq("type" => "error", "step" => "3f")
    end
  end

  describe "a message that isn't of a whitelisted type" do
    [
      ["an unknown type", { type: :result_rows, rows: [[EGRESS_SENTINEL]] }],
      ["an unknown String type", { "type" => "fixture", "contents" => EGRESS_SENTINEL }],
      ["a type that differs only in case", { type: "Error", step: EGRESS_SENTINEL }],
      ["no type", { step: "3f", rule: EGRESS_SENTINEL }],
      ["no type, but a nil key holding a type's name", { nil => :error, step: EGRESS_SENTINEL }],
      ["a nil type", { type: nil, step: EGRESS_SENTINEL }],
      ["a type that's neither a Symbol nor a String", { type: [:error], step: EGRESS_SENTINEL }],
      ["a type named by a field", { type: :step, step: EGRESS_SENTINEL }],
      ["a String", EGRESS_SENTINEL],
      ["an Array", [%i[type error], [:step, EGRESS_SENTINEL]]],
      ["nil", nil]
    ].each do |name, message|
      it "sends nothing for #{name}" do
        expect(egress.serialize(message)).to be_nil
      end
    end
  end

  describe "a message that names a key twice, as a Symbol and as a String" do
    it "sends nothing when the type is named twice" do
      expect(egress.serialize(:type => :error, "type" => :column_stats, :step => EGRESS_SENTINEL)).to be_nil
    end

    it "sends nothing when an allowed field is named twice" do
      expect(egress.serialize(:type => :error, :step => "3f", "step" => EGRESS_SENTINEL)).to be_nil
    end

    it "still sends the message when only a dropped field is named twice" do
      out = egress.serialize(:type => :error, :step => "3f", :detail => EGRESS_SENTINEL, "detail" => EGRESS_SENTINEL)

      expect(JSON.parse(out)).to eq("type" => "error", "step" => "3f")
    end
  end

  describe "an allowed field whose value can't be written as JSON" do
    [
      ["invalid UTF-8", "#{EGRESS_SENTINEL}\xFF"],
      ["a NaN", Float::NAN]
    ].each do |name, value|
      it "raises Egress::Error that carries nothing from the message, for #{name}" do
        error = nil
        begin
          egress.serialize(type: :error, step: "3f", rule: value, detail: EGRESS_SENTINEL)
        rescue StandardError => e
          error = e
        end

        expect(error).to be_a(described_class::Error)
        expect(error.message).to eq("a value in this error message can't be written as JSON")
        expect(error.cause).to be_nil
        [error.message, error.full_message, error.detailed_message, error.inspect].each do |text|
          expect(text).not_to include(EGRESS_SENTINEL)
        end
        expect(error.instance_variables).to be_empty
      end
    end
  end
end
