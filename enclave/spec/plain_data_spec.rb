# frozen_string_literal: true

require "timeout"
require "quaack/enclave/plain_data"

PLAIN_SENTINEL = "SENTINEL-71c0b4-accounts.token"

RSpec.describe Quaack::Enclave::PlainData do
  let(:plain) { described_class }
  let(:max) { described_class::MAX_DEPTH }

  def nested(depth, leaf = 1) = depth.times.reduce(leaf) { |inner, _| [inner] }

  def expect_not_plain(value)
    expect { plain.check(value) }.to raise_error(described_class::NotPlain) do |error|
      expect(error.message).not_to include(PLAIN_SENTINEL)
      expect(error.cause).to be_nil
    end
  end

  it "returns plain JSON data unchanged" do
    value = { "a" => [1, 2.5, nil, true, false, { b: "x" }], c: :d }

    expect(plain.check(value)).to equal(value)
  end

  it "sees the sentinel when it's plain data, so the check below can find it" do
    expect(plain.check([PLAIN_SENTINEL])).to include(PLAIN_SENTINEL)
  end

  sentinel_object = Object.new.tap { |o| o.define_singleton_method(:to_s) { PLAIN_SENTINEL } }
  string_subclass = Class.new(String) { def to_s = PLAIN_SENTINEL }
  [
    ["an object", -> { sentinel_object }],
    ["a BasicObject", -> { BasicObject.new }],
    ["a BasicObject in an Array", -> { [1, BasicObject.new] }],
    ["an exception", -> { RuntimeError.new(PLAIN_SENTINEL) }],
    ["a String subclass", -> { string_subclass.new("x") }],
    ["a Hash subclass", -> { Class.new(Hash)[a: 1] }],
    ["an Array subclass", -> { Class.new(Array).new([1]) }],
    ["a Struct", -> { Struct.new(:email).new(PLAIN_SENTINEL) }],
    ["a Time", -> { Time.at(0) }],
    ["a Range", -> { 1..2 }],
    ["a Rational", -> { Rational(1, 3) }],
    ["an object as a Hash key", -> { { sentinel_object => 1 } }],
    ["an Integer Hash key", -> { { 1 => PLAIN_SENTINEL } }],
    ["a String subclass as a Hash key", -> { { string_subclass.new("a") => 1 } }],
    ["a Hash that names a key twice", -> { { :a => 1, "a" => PLAIN_SENTINEL } }],
    ["a nested Hash that names a key twice", -> { [{ "a" => { :b => 1, "b" => 2 } }] }],
    ["non-plain data deep inside plain data", -> { { "a" => [{ "b" => [sentinel_object] }] } }],
    ["an object first in an Array", -> { [sentinel_object, 1, 2] }],
    ["an object in the middle of an Array", -> { [1, sentinel_object, 2] }],
    ["an object last in an Array", -> { [1, 2, sentinel_object] }],
    ["an object first in a Hash", -> { { "a" => sentinel_object, "b" => 1, "c" => 2 } }],
    ["an object in the middle of a Hash", -> { { "a" => 1, "b" => sentinel_object, "c" => 2 } }],
    ["an object last in a Hash", -> { { "a" => 1, "b" => 2, "c" => sentinel_object } }]
  ].each do |name, value|
    it "raises NotPlain, carrying nothing from the value, for #{name}" do
      expect_not_plain(instance_exec(&value))
    end
  end

  describe "depth" do
    # Without the depth cap, data that contains itself would loop forever.
    # The timeout turns that into a failure instead of a hang.
    around { |example| Timeout.timeout(30) { example.run } }

    it "takes data nested MAX_DEPTH deep, well above any plan's depth" do
      # The deepest real pg_query tree seen is about 1,500 levels.
      expect(max).to be >= 2_000
      deep = nested(max)

      expect(plain.check(deep)).to equal(deep)
    end

    # How deep JSON can go before it runs out of stack depends on the
    # platform: the Store spec's 4 MB-thread test still passes on macOS
    # with MAX_DEPTH at 6,000, which would likely fail on aarch64 Linux,
    # where the jump servers run. So the value chosen from the measurements
    # (see MAX_DEPTH) is pinned here, and the tests either side of this one
    # pin the behavior at MAX_DEPTH and one deeper.
    it "is 3,000, the depth chosen from the stack measurements on aarch64 Linux and macOS" do
      expect(max).to eq(3_000)
    end

    it "raises NotPlain for data nested one deeper than MAX_DEPTH" do
      expect_not_plain(nested(max + 1, PLAIN_SENTINEL))
    end

    it "counts Hashes as well as Arrays" do
      half = (max / 2) + 1
      value = half.times.reduce(1) { |inner, _| { "a" => [inner] } }

      expect_not_plain(value)
    end

    it "raises NotPlain, not SystemStackError, for data nested 100,000 deep" do
      expect_not_plain(nested(100_000))
    end

    it "raises NotPlain for an Array that contains itself" do
      loop = [1]
      loop << loop

      expect_not_plain(loop)
    end

    it "raises NotPlain for a Hash that contains itself" do
      loop = {}
      loop["self"] = loop

      expect_not_plain(loop)
    end
  end
end
