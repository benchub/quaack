# frozen_string_literal: true

require "quaack/protocol/unreadable_reasons"

# The one list of intake's unreadable causes (DESIGN.md's input), which the
# enclave sends and the driver shapes and words.
RSpec.describe Quaack::Protocol::UnreadableReasons do
  it "names the two rules and the six fixed causes" do
    expect(described_class::RULES).to eq(%w[query_unreadable plan_unreadable])
    expect(described_class::NAMES)
      .to eq(%w[missing symlink not_regular_file permission_denied name_too_long io_error])
  end

  it "is frozen, and every cause is a plain lowercase word with underscores" do
    expect([described_class::RULES.frozen?, described_class::NAMES.frozen?]).to eq([true, true])
    expect(described_class::NAMES).to all(match(/\A[a-z]+(_[a-z]+)*\z/))
  end
end
