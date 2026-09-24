# frozen_string_literal: true

require "open3"
require "rbconfig"
require "quaack/protocol/burndown"

# The burndown's shared names. The enclave records stage counts under STAGES
# and the driver counts LLM calls under LLM_STEPS, so both sides use one list.
RSpec.describe Quaack::Protocol::Burndown do
  it "lists each stage of the README 15b tables once, as a frozen String" do
    expect(described_class::STAGES).to eq(%w[5a-1 5a-2 5a-3 5a-4 5a-5 5a-6 5a-7 6a 6b
                                             step7 step8 step9 step10 step11 step14])
    expect(described_class::STAGES).to be_frozen.and(all(be_frozen))
  end

  it "lists the driver steps that call an LLM, once each, as frozen Strings" do
    expect(described_class::LLM_STEPS).to eq(%w[5a-5 5a-6 6a step7 10a step11])
    expect(described_class::LLM_STEPS).to be_frozen.and(all(be_frozen))
  end

  it "takes a name only if it's a lowercase word of at most 63 characters" do
    name = described_class::NAME
    expect(%w[original duplicate generator_one rewrite_3].map { name.match?(it) }).to all(be(true))
    expect(["", "Duplicate", "3rd", "a-b", "a b", "a\n", "bob@x.com", "a" * 64].map { name.match?(it) })
      .to all(be(false))
    expect(name.match?("a" * 63)).to be(true)
  end

  it "is loaded by quaack/protocol" do
    lib = File.join(GEM_ROOT, "lib")
    out, err, status = Bundler.with_unbundled_env do
      Open3.capture3(RbConfig.ruby, "--disable-gems", "-I", lib,
                     "-e", 'require "quaack/protocol"; print Quaack::Protocol::Burndown::STAGES.size')
    end

    expect(status).to be_success, "stderr was #{err}"
    expect(Integer(out)).to eq(described_class::STAGES.size)
  end
end
