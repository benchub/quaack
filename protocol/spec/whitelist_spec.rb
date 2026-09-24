# frozen_string_literal: true

require "quaack/protocol/whitelist"

# The whitelist's contents get reviewed in the git diff, not pinned here (see
# BACKLOG-COMPLETE.md, 20260922-7). These specs check only its shape, which
# the enclave's egress function relies on.
RSpec.describe "Quaack::Protocol::WHITELIST" do
  let(:whitelist) { Quaack::Protocol::WHITELIST }

  it "maps each output type, as a Symbol, to an Array of Symbol field names" do
    expect(whitelist).to be_a(Hash)
    expect(whitelist).not_to be_empty
    whitelist.each do |type, fields|
      expect(type).to be_a(Symbol)
      expect(fields).to be_an(Array).and(all(be_a(Symbol))), "#{type} has #{fields.inspect}"
    end
  end

  it "can't be changed at runtime, only in its file" do
    expect(whitelist).to be_frozen
    whitelist.each_value { |fields| expect(fields).to be_frozen }
  end

  it "never lists type as a field, since every message's type key names its type" do
    whitelist.each { |type, fields| expect(fields).not_to include(:type), "#{type} lists type" }
  end

  it "lists each field once per type" do
    whitelist.each { |type, fields| expect(fields).to eq(fields.uniq), "#{type} repeats a field" }
  end

  it "is loaded by quaack/protocol" do
    lib = File.join(GEM_ROOT, "lib")
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "--disable-gems", "-I", lib,
                     "-e", 'require "quaack/protocol"; print Quaack::Protocol::WHITELIST.keys.size')
    end

    expect(status).to be_success, "stderr was #{err}"
    expect(Integer(out)).to eq(whitelist.size)
  end
end
