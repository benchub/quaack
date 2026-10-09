# frozen_string_literal: true

require "quaack/enclave"

RSpec.describe Quaack::Enclave::RewriteEntry do
  describe ".run_sql" do
    it "returns the entry's anchored_sql, not its sql" do
      entry = { "sql" => "SELECT now()", "anchored_sql" => "SELECT quaack.clock_anchor()" }
      expect(described_class.run_sql(entry)).to eq("SELECT quaack.clock_anchor()")
    end

    it "refuses an entry without anchored_sql instead of running its unanchored sql" do
      expect { described_class.run_sql({ "sql" => "SELECT now()" }) }.to raise_error(KeyError, /anchored_sql/)
    end
  end
end
