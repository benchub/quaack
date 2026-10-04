# frozen_string_literal: true

require "json"
require "timeout"
require "quaack/enclave/egress"

# Stands in for a real production value. It must never show up in what
# Egress.serialize returns, or in anything it raises.
EGRESS_SENTINEL = "SENTINEL-8f3a2c-orders.email"

# Answers each_key and [] like a Hash holding an error message, but isn't one.
EGRESS_HASH_LIKE = Class.new do
  def each_key(&) = %i[type step].each(&)
  def [](key) = { type: :error, step: EGRESS_SENTINEL }[key]
end

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
      out = egress.serialize(type: :error, step: "classify", rule: EGRESS_SENTINEL)

      expect(out).to include(EGRESS_SENTINEL)
    end
  end

  describe "a message of a whitelisted type" do
    it "keeps an error's allowed fields and drops the rest" do
      out = egress.serialize(type: :error, step: "classify", rule: "unique_violation", sqlstate: "23505",
                             message: "Key (email)=(#{EGRESS_SENTINEL}) already exists.",
                             detail: EGRESS_SENTINEL, backtrace: [EGRESS_SENTINEL])

      expect(JSON.parse(out)).to eq("type" => "error", "step" => "classify", "rule" => "unique_violation",
                                    "sqlstate" => "23505")
      expect(out).not_to include(EGRESS_SENTINEL)
    end

    it "sends done, a type with no fields, as its type alone, and drops any field" do
      expect(whitelist.fetch(:done)).to eq([])
      expect(egress.serialize(type: :done)).to eq('{"type":"done"}')
      expect(egress.serialize("type" => "done", "rule" => EGRESS_SENTINEL)).to eq('{"type":"done"}')
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
      # A burndown's fields must be a burndown, so it gets its own tests below.
      whitelist.except(:burndown).each do |type, fields|
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
      expect(parsed(type: :error, step: "classify")).to eq("type" => "error", "step" => "classify")
    end

    it "sends an allowed field that's present but nil as null" do
      expect(parsed(type: :error, step: "classify", sqlstate: nil))
        .to eq("type" => "error", "step" => "classify", "sqlstate" => nil)
    end

    it "treats String keys and a String type the same as Symbols" do
      symbols = egress.serialize(type: :error, step: "classify", rule: "r", sqlstate: "23505", detail: EGRESS_SENTINEL)
      strings = egress.serialize("type" => "error", "step" => "classify", "rule" => "r", "sqlstate" => "23505",
                                 "detail" => EGRESS_SENTINEL)
      mixed = egress.serialize(:type => "error", "step" => "classify", :rule => "r", "sqlstate" => "23505",
                               "detail" => EGRESS_SENTINEL, :message => EGRESS_SENTINEL)

      expect(strings).to eq(symbols)
      expect(mixed).to eq(symbols)
      expect(JSON.parse(strings)).to eq("type" => "error", "step" => "classify", "rule" => "r", "sqlstate" => "23505")
    end

    it "drops keys that are neither Symbols nor Strings, even one whose to_s is a field name" do
      rule = Object.new
      def rule.to_s = "rule"
      out = egress.serialize(type: :error, step: "classify", 1 => EGRESS_SENTINEL, rule => EGRESS_SENTINEL)

      expect(JSON.parse(out)).to eq("type" => "error", "step" => "classify")
    end
  end

  describe "a message that isn't of a whitelisted type" do
    [
      ["an unknown type", { type: :result_rows, rows: [[EGRESS_SENTINEL]] }],
      ["an unknown String type", { "type" => "fixture", "contents" => EGRESS_SENTINEL }],
      ["a type that differs only in case", { type: "Error", step: EGRESS_SENTINEL }],
      ["no type", { step: "classify", rule: EGRESS_SENTINEL }],
      ["no type, but a nil key holding a type's name", { nil => :error, step: EGRESS_SENTINEL }],
      ["a nil type", { type: nil, step: EGRESS_SENTINEL }],
      ["a type that's neither a Symbol nor a String", { type: [:error], step: EGRESS_SENTINEL }],
      ["a type named by a field", { type: :step, step: EGRESS_SENTINEL }],
      ["a String", EGRESS_SENTINEL],
      ["an Array", [%i[type error], [:step, EGRESS_SENTINEL]]],
      ["nil", nil],
      ["a Hash-like object with each_key and []", EGRESS_HASH_LIKE.new]
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
      expect(egress.serialize(:type => :error, :step => "classify", "step" => EGRESS_SENTINEL)).to be_nil
    end

    it "still sends the message when only a dropped field is named twice" do
      out = egress.serialize(:type => :error, :step => "classify", :detail => EGRESS_SENTINEL,
                             "detail" => EGRESS_SENTINEL)

      expect(JSON.parse(out)).to eq("type" => "error", "step" => "classify")
    end
  end

  describe "the type" do
    it "goes out as the whitelist's own name, not the caller's object" do
      type = Class.new(String) { def to_json(*) = %("#{EGRESS_SENTINEL}") }.new("error")

      expect(egress.serialize(type: type, step: "classify")).to eq('{"type":"error","step":"classify"}')
    end

    it "isn't found through to_s, so an object whose to_s is a type's name sends nothing" do
      type = Object.new
      def type.to_s = "error"

      expect(egress.serialize(type: type, step: EGRESS_SENTINEL)).to be_nil
    end
  end

  describe "a burndown message" do
    let(:record) do
      { "in" => 2, "added" => {}, "dropped" => { "duplicate" => 1 }, "set_aside" => 0, "out" => 1, "extra" => {} }
    end

    it "sends stages and totals that are a burndown as they are" do
      stages = { "index-dedupe" => { "original" => record } }
      out = egress.serialize(type: :burndown, stages:, totals: { "fixture_loads" => 3 }, rows: EGRESS_SENTINEL)

      expect(JSON.parse(out)).to eq("type" => "burndown", "stages" => stages, "totals" => { "fixture_loads" => 3 })
    end

    it "the sentinel check itself: an error field carries the same nested value out" do
      out = egress.serialize(type: :error, rule: { "index-dedupe" => { "orders_email" => EGRESS_SENTINEL } })

      expect(out).to include(EGRESS_SENTINEL)
    end

    [
      ["a value in place of a count", { "index-dedupe" => { "original" => { "in" => EGRESS_SENTINEL } } }, {}],
      ["a value as a search", { "index-dedupe" => { EGRESS_SENTINEL => { "in" => 0 } } }, {}],
      ["a value as a stage", { EGRESS_SENTINEL => {} }, {}],
      ["a value as a total", {}, { "fixture_loads" => EGRESS_SENTINEL }],
      ["a value as a total's name", {}, { EGRESS_SENTINEL => 1 }],
      ["an extra field in a record", { "index-dedupe" => { "original" => { "rows" => [EGRESS_SENTINEL] } } }, {}]
    ].each do |what, stages, totals|
      it "refuses one with #{what}, built by hand, without quoting it" do
        expect { egress.serialize(type: :burndown, stages:, totals:) }
          .to raise_error(described_class::Error, "a value in this burndown message isn't a burndown") { |e|
            expect(e.message).not_to include(EGRESS_SENTINEL)
            expect(e.cause).to be_nil
          }
      end
    end

    it "refuses one missing stages or totals, since the check needs both" do
      expect { egress.serialize(type: :burndown, stages: {}) }.to raise_error(described_class::Error)
      expect { egress.serialize(type: :burndown, totals: {}) }.to raise_error(described_class::Error)
    end
  end

  it "sends plain data nested in an allowed field as is, with Symbols as their names" do
    value = { "a" => [1, 2.5, nil, true, false, { b: "x" }], c: :d }

    expect(parsed(type: :error, step: :classify, rule: value))
      .to eq("type" => "error", "step" => "classify", "rule" => { "a" => [1, 2.5, nil, true, false, { "b" => "x" }],
                                                                  "c" => "d" })
  end

  describe "an allowed field whose value isn't plain JSON data" do
    def sentinel_object(method)
      Object.new.tap { |o| o.define_singleton_method(method) { |*| %("#{EGRESS_SENTINEL}") } }
    end

    sentinel_string = Class.new(String) { def to_json(*) = %("#{EGRESS_SENTINEL}") }
    sentinel_hash = Class.new(Hash) { def to_json(*) = %("#{EGRESS_SENTINEL}") }
    sentinel_array = Class.new(Array) { def to_json(*) = %("#{EGRESS_SENTINEL}") }
    [
      ["invalid UTF-8", -> { "#{EGRESS_SENTINEL}\xFF" }],
      ["a NaN", -> { Float::NAN }],
      ["Arrays nested deeper than JSON writes", -> { 200.times.reduce(EGRESS_SENTINEL) { |v, _| [v] } }],
      ["an exception", -> { RuntimeError.new("Key (email)=(#{EGRESS_SENTINEL}) already exists.") }],
      ["an object with its own to_s", -> { sentinel_object(:to_s) }],
      ["an object with its own to_json", -> { sentinel_object(:to_json) }],
      ["an object with its own to_s, in an Array", -> { [1, sentinel_object(:to_s)] }],
      ["an object with its own to_s, as a Hash key", -> { { sentinel_object(:to_s) => 1 } }],
      ["an Integer Hash key", -> { { 1 => EGRESS_SENTINEL } }],
      ["a Hash that names a key twice", -> { { :a => 1, "a" => EGRESS_SENTINEL } }],
      ["a String subclass with its own to_json", -> { sentinel_string.new("x") }],
      ["a Hash subclass with its own to_json", -> { sentinel_hash[a: 1] }],
      ["an Array subclass with its own to_json", -> { sentinel_array.new([1]) }],
      ["a Struct", -> { Struct.new(:email).new(EGRESS_SENTINEL) }],
      ["a Time", -> { Time.at(0) }],
      ["a Range", -> { EGRESS_SENTINEL..EGRESS_SENTINEL }],
      ["a Rational", -> { Rational(1, 3) }],
      ["a BasicObject", -> { BasicObject.new }],
      ["Arrays nested 100,000 deep", -> { 100_000.times.reduce(EGRESS_SENTINEL) { |v, _| [v] } }],
      ["an Array that contains itself", -> { [EGRESS_SENTINEL].tap { |a| a << a } }]
    ].each do |name, value|
      it "raises Egress::Error that carries nothing from the message, for #{name}" do
        error = nil
        begin
          # A value that contains itself would loop forever without the
          # depth cap in PlainData. The timeout makes that a failure.
          Timeout.timeout(30) do
            egress.serialize(type: :error, step: "classify", rule: instance_exec(&value), detail: EGRESS_SENTINEL)
          end
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

  describe "a value that isn't plain JSON data beside plain ones" do
    let(:bad) { Object.new.tap { |o| o.define_singleton_method(:to_s) { EGRESS_SENTINEL } } }

    [
      ["in the first field", ->(bad) { { step: bad, rule: "ok", sqlstate: "23505" } }],
      ["in a middle field", ->(bad) { { step: "classify", rule: bad, sqlstate: "23505" } }],
      ["in the last field", ->(bad) { { step: "classify", rule: "ok", sqlstate: bad } }],
      ["first in an Array", ->(bad) { { step: "classify", rule: [bad, 1, 2] } }],
      ["in the middle of an Array", ->(bad) { { step: "classify", rule: [1, bad, 2] } }],
      ["last in an Array", ->(bad) { { step: "classify", rule: [1, 2, bad] } }],
      ["first in a Hash", ->(bad) { { step: "classify", rule: { "a" => bad, "b" => 1, "c" => 2 } } }],
      ["in the middle of a Hash", ->(bad) { { step: "classify", rule: { "a" => 1, "b" => bad, "c" => 2 } } }],
      ["last in a Hash", ->(bad) { { step: "classify", rule: { "a" => 1, "b" => 2, "c" => bad } } }]
    ].each do |name, fields|
      it "raises Egress::Error for one #{name}" do
        expect { egress.serialize(type: :error, **fields.call(bad)) }
          .to raise_error(described_class::Error, "a value in this error message can't be written as JSON")
      end
    end

    it "the sentinel check itself: the bad value's to_s is the sentinel" do
      expect(JSON.generate([bad])).to include(EGRESS_SENTINEL)
    end
  end

  # The jump server runs the enclave outside Bundler, so it gets the json
  # that ships with Ruby, not the newer one in this bundle. The two differ
  # on what they let through, so check the cases that differ against the
  # shipped one too.
  it "treats non-plain data the same with the json that ships with Ruby" do
    script = <<~RUBY
      require "quaack/enclave/egress"
      key = Object.new
      def key.to_s = "#{EGRESS_SENTINEL}"
      [{ key => 1 }, [{ key => 1 }], { "a" => { key => 1 } }, { 1 => 2 }, { :a => 1, "a" => 2 },
       [{ :a => 1, "a" => 2 }], :d, [:d], { "a" => :d }].each do |value|
        puts Quaack::Enclave::Egress.serialize(type: :error, rule: value)
      rescue Quaack::Enclave::Egress::Error => e
        puts e.class
      end
      puts $LOADED_FEATURES.grep(%r{/json\\.rb\\z}).first
    RUBY
    libs = [GEM_ROOT, File.join(GEM_ROOT, "..", "protocol")].flat_map { |dir| ["-I", File.join(dir, "lib")] }
    out, err, status = Bundler.with_unbundled_env { run_ruby("--disable-gems", *libs, "-e", script) }

    expect(status).to be_success, "stderr was #{err}"
    *results, json = out.lines(chomp: true)
    expect(results).to eq([*["Quaack::Enclave::Egress::Error"] * 6, '{"type":"error","rule":"d"}',
                           '{"type":"error","rule":["d"]}', '{"type":"error","rule":{"a":"d"}}'])
    expect(File.realpath(json)).to start_with(File.realpath(RbConfig::CONFIG["rubylibdir"]))
  end
end
