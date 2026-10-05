# frozen_string_literal: true

require "quaack/protocol/port"

# The one check of a port the operator gives: `quaack start --port`, which
# `quaacks intake --port` checks again, and `quaacks run-server --port`.
RSpec.describe Quaack::Protocol::Port do
  it "takes a whole number from 1 to 65535, written with plain digits" do
    %w[1 5432 6543 65535].each { expect(described_class.valid?(it)).to be(true), it }
  end

  it "refuses anything else" do
    ["", "0", "65536", "-1", "+5432", " 5432", "5432\n", "54a", "5432.0", "0x10", "05432", "99999999",
     "５４３２", nil, 5432].each { expect(described_class.valid?(it)).to be(false), it.inspect }
  end

  # Task 20261004-22: argv can hold any bytes, so a bad encoding is refused,
  # not raised on.
  it "refuses, without raising, invalid UTF-8, UTF-16, and other non-ASCII encodings" do
    ["\xff", "54\xff32", "5432\xff", "5432".encode("UTF-16LE"), "5432".encode("UTF-16BE"),
     "5432".encode("UTF-16"), "5432".encode("UTF-32LE"), "\xff".dup.force_encoding("Shift_JIS"),
     "5432\xff".b].each { expect(described_class.valid?(it)).to be(false), "#{it.inspect} (#{it.encoding})" }
  end
end
