# frozen_string_literal: true

require "quaack/enclave/structured_literal"

# What each part of an array, range, multirange, or composite literal is,
# as Postgres's input functions read it.
RSpec.describe Quaack::Enclave::StructuredLiteral do
  describe ".array" do
    {
      "{a,b}" => %w[a b],
      " { a , b } " => %w[a b],
      "{}" => [],
      "[1:2]={a,b}" => %w[a b],
      "[0:0][1:1]={{x}}" => %w[x],
      "{{a,b},{c,d}}" => %w[a b c d],
      '{"a,b","c\\"d",e\\,f}' => ["a,b", 'c"d', "e,f"],
      '{to\\day}' => %w[today],
      '{NULL,null,"NULL"}' => [nil, nil, "NULL"],
      '{"  a  "}' => ["  a  "]
    }.each do |text, parts|
      it "reads #{text} as #{parts}" do
        expect(described_class.array(text)).to eq(parts)
      end
    end

    ["{a", "a}", "{a}x", "{{a}"].each do |text|
      it "refuses #{text}" do
        expect { described_class.array(text) }.to raise_error(ArgumentError, "malformed structured literal")
      end
    end
  end

  describe ".range" do
    {
      "[a,b)" => %w[a b],
      " (a,b] " => %w[a b],
      "EMPTY" => [],
      "[,b)" => [nil, "b"],
      "[a,)" => ["a", nil],
      '["a""b","c\\)"]' => ['a"b', "c)"],
      '[to\\day,"")' => ["today", ""]
    }.each do |text, parts|
      it "reads #{text} as #{parts}" do
        expect(described_class.range(text)).to eq(parts)
      end
    end

    ["[a,b", "a,b)", "[a)", "[a,b)x"].each do |text|
      it "refuses #{text}" do
        expect { described_class.range(text) }.to raise_error(ArgumentError, "malformed structured literal")
      end
    end
  end

  describe ".multirange" do
    {
      "{}" => [],
      " { [a,b) , empty, (\"c,]\",d] } " => ["[a,b)", "empty", '("c,]",d]']
    }.each do |text, parts|
      it "reads #{text} as #{parts}" do
        expect(described_class.multirange(text)).to eq(parts)
      end
    end

    ["{[a,b)", "{[a,b) x}"].each do |text|
      it "refuses #{text}" do
        expect { described_class.multirange(text) }.to raise_error(ArgumentError, "malformed structured literal")
      end
    end
  end

  describe ".record" do
    {
      "(a,b)" => %w[a b],
      " (a, b ) " => ["a", " b "],
      "()" => [nil],
      "(,)" => [nil, nil],
      '("a""b",c\\,d,"")' => ['a"b', "c,d", ""],
      '(x"y,z"w)' => ["xy,zw"]
    }.each do |text, parts|
      it "reads #{text} as #{parts}" do
        expect(described_class.record(text)).to eq(parts)
      end
    end

    ["(a", "a)", "(a)x", '("a)'].each do |text|
      it "refuses #{text}" do
        expect { described_class.record(text) }.to raise_error(ArgumentError, "malformed structured literal")
      end
    end
  end
end
