# frozen_string_literal: true

require "quaack/enclave/arena_runner"

# Task 20261008-55: a cancel QUAACK didn't send ends the step whether it hit
# the query or the BEGIN or ROLLBACK around it, but QUAACK's own timeout
# still counts as a disproof.
RSpec.describe Quaack::Enclave::ArenaRunner::Cancel do
  def error(rule, step) = Quaack::Enclave::ArenaRunner::Error.new(rule, step:, sqlstate: "57014")

  it "calls a statement_canceled on the query, BEGIN, ROLLBACK, or transaction foreign" do
    expect(%i[query begin rollback transaction].map { described_class.foreign?(error(:statement_canceled, it)) })
      .to eq([true, true, true, true])
  end

  it "doesn't call QUAACK's own statement_timeout foreign, on any step" do
    expect(%i[query begin rollback transaction].map { described_class.foreign?(error(:statement_timeout, it)) })
      .to eq([false, false, false, false])
  end

  it "doesn't call a cancel while loading the fixture foreign, since that's a load failure" do
    expect(%i[load insert].map { described_class.foreign?(error(:statement_canceled, it)) }).to eq([false, false])
  end
end
