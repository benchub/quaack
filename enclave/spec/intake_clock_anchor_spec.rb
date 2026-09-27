# frozen_string_literal: true

require "quaack/enclave/intake/clock_anchor"

RSpec.describe Quaack::Enclave::Intake::ClockAnchor do
  let(:now) { Time.utc(2026, 9, 26, 12) }

  it "takes a time exactly FUTURE_SLACK after now, and refuses one a microsecond later" do
    expect(described_class.from("2026-09-27T12:00:00Z", now:)).to eq("2026-09-27T12:00:00.000000Z")
    expect { described_class.from("2026-09-27T12:00:00.000001Z", now:) }
      .to raise_error(Quaack::Enclave::Intake::Error, "bad_captured_at")
  end
end
