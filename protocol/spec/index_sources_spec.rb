# frozen_string_literal: true

require "open3"
require "rbconfig"
require "quaack/protocol/index_sources"

# The one check on the report's index_sources: how many of the indexes
# QUAACK built each source proposed, for the enclave's egress function and
# the driver both. Only counts, under QUAACK's own source names.
RSpec.describe Quaack::Protocol::IndexSources do
  let(:sentinel) { "SENTINEL_INDEX_SOURCE_5c1e" }
  let(:counts) { { "built" => 3, "not_better" => 1, "ranked" => 2, "existed" => 4, "ignored" => 5 } }
  let(:field) do
    { "generator_one" => counts,
      "generator_two" => { "built" => 0, "not_better" => 0, "ranked" => 0, "existed" => 0, "ignored" => 0 },
      "llm" => { "built" => 1, "not_better" => 0, "ranked" => 1, "existed" => 2, "ignored" => 0 } }
  end

  def valid?(value) = described_class.valid?(value)

  it "lists QUAACK's own index sources and the outcomes it counts for each, as frozen Strings" do
    expect(described_class::SOURCES).to eq(%w[generator_one generator_two llm])
    expect(described_class::COLUMNS).to eq(%w[built not_better ranked existed ignored])
    [described_class::SOURCES, described_class::COLUMNS].each { expect(it).to be_frozen.and(all(be_frozen)) }
  end

  it "takes a count of each outcome for each source, in any order" do
    expect(valid?(field)).to be(true)
    expect(valid?(field.to_a.reverse.to_h.transform_values { it.to_a.reverse.to_h })).to be(true)
  end

  it "refuses one that isn't a Hash" do
    [nil, [], "llm", field.to_a, 3].each { expect(valid?(it)).to be(false), it.inspect }
  end

  it "refuses a source that isn't one of QUAACK's own, such as a planted sentinel" do
    expect(valid?(field.merge(sentinel => counts))).to be(false)
    expect(valid?(field.merge("existing" => counts))).to be(false)
    expect(valid?(field.except("llm").merge(sentinel => counts))).to be(false)
    expect(valid?(field.merge(llm: counts))).to be(false)
  end

  it "refuses one missing a source" do
    described_class::SOURCES.each { expect(valid?(field.except(it))).to be(false), it }
  end

  it "refuses a source's counts with an outcome that isn't one of them, or missing one" do
    expect(valid?(field.merge("llm" => counts.merge(sentinel => 1)))).to be(false)
    expect(valid?(field.merge("llm" => counts.merge("index" => sentinel)))).to be(false)
    described_class::COLUMNS.each { expect(valid?(field.merge("llm" => counts.except(it)))).to be(false), it }
    expect(valid?(field.merge("llm" => counts.transform_keys(&:to_sym)))).to be(false)
  end

  it "refuses a count that isn't an Integer from zero up, such as a planted sentinel" do
    [sentinel, "3", 3.0, -1, nil, true, [3], { sentinel => 3 }, 10**12].each do |bad|
      described_class::COLUMNS.each do |column|
        expect(valid?(field.merge("llm" => counts.merge(column => bad)))).to be(false), "#{column}: #{bad.inspect}"
      end
    end
  end

  it "refuses a source's counts that aren't a Hash" do
    [nil, 3, sentinel, [counts], counts.to_a].each do |bad|
      expect(valid?(field.merge("generator_two" => bad))).to be(false), bad.inspect
    end
  end

  it "refuses more not better or ranked indexes than were built" do
    expect(valid?(field.merge("llm" => counts.merge("not_better" => 4)))).to be(false)
    expect(valid?(field.merge("llm" => counts.merge("ranked" => 4)))).to be(false)
    expect(valid?(field.merge("llm" => counts.merge("not_better" => 3, "ranked" => 3, "existed" => 9)))).to be(true)
  end

  it "is loaded by quaack/protocol" do
    lib = File.join(GEM_ROOT, "lib")
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "--disable-gems", "-I", lib,
                     "-e", 'require "quaack/protocol"; print Quaack::Protocol::IndexSources::SOURCES.join(",")')
    end

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq(described_class::SOURCES.join(","))
  end
end
