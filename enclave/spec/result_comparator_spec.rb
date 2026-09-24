# frozen_string_literal: true

require "quaack/enclave/result_comparator"

# Step 9d's comparator over two results built by hand. See
# result_comparison_postgres_spec.rb for the rules run against Postgres.
RSpec.describe Quaack::Enclave::ResultComparator do
  INT4 = 23
  INT8 = 20
  TEXT = 25
  FLOAT4 = 700
  FLOAT8 = 701
  NUMERIC = 1700

  let(:sentinel) { "SENTINEL-47c1d9" }

  def result(types, rows, columns: types.each_index.map { |i| "c#{i}" })
    Quaack::Enclave::ArenaRunner::Result.new(columns:, types:, rows:)
  end

  def compare(expected, actual, mode: :multiset, **)
    described_class.compare(expected, actual, mode:, **)
  end

  # One-column float8 results, one value each.
  def floats(expected, actual, type: FLOAT8)
    compare(result([type], [[expected]]), result([type], [[actual]]), mode: :ordered)
  end

  def verdict_fields(verdict)
    verdict.to_h.slice(:match, :mode, :rule, :expected_rows, :actual_rows, :row, :column)
  end

  describe "columns" do
    it "is a column_count mismatch when the column counts differ" do
      verdict = compare(result([INT4], [["1"]]), result([INT4, INT4], [%w[1 2]]))

      expect(verdict_fields(verdict)).to eq(match: false, mode: :multiset, rule: :column_count,
                                            expected_rows: 1, actual_rows: 1, row: nil, column: nil)
    end

    it "is a column_types mismatch at the first column whose type differs, even int4 against int8" do
      verdict = compare(result([TEXT, INT4, INT4], [%w[a 1 1]]), result([TEXT, INT8, TEXT], [%w[a 1 1]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :column_types, column: 1)
    end

    it "ignores column names" do
      verdict = compare(result([INT4], [["1"]], columns: ["id"]), result([INT4], [["1"]], columns: ["other"]))

      expect(verdict.match?).to be(true)
    end
  end

  describe "multiset mode" do
    it "matches the same rows in a different order" do
      verdict = compare(result([INT4, TEXT], [%w[1 a], %w[2 b], %w[3 c]]),
                        result([INT4, TEXT], [%w[3 c], %w[1 a], %w[2 b]]))

      expect(verdict_fields(verdict)).to eq(match: true, mode: :multiset, rule: nil,
                                            expected_rows: 3, actual_rows: 3, row: nil, column: nil)
    end

    it "is a row_count mismatch when the counts differ" do
      verdict = compare(result([INT4], [["1"], ["2"]]), result([INT4], [["1"]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :row_count, expected_rows: 2, actual_rows: 1)
    end

    it "counts duplicates, so the same rows with different multiplicities don't match" do
      verdict = compare(result([INT4], [["1"], ["1"], ["2"]]), result([INT4], [["1"], ["2"], ["2"]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :multiset, row: 2)
    end

    it "is a multiset mismatch at the first candidate row with no partner" do
      verdict = compare(result([INT4, TEXT], [%w[1 a], %w[2 b]]), result([INT4, TEXT], [%w[2 b], %w[1 z]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :multiset, row: 1, column: nil)
    end

    it "matches floats within tolerance in a different order" do
      verdict = compare(result([FLOAT8], [["1"], ["2"]]), result([FLOAT8], [["2.0000000001"], ["1.0000000001"]]))

      expect(verdict.match?).to be(true)
    end

    it "doesn't match floats outside tolerance" do
      verdict = compare(result([FLOAT8], [["1"], ["2"]]), result([FLOAT8], [["2.00001"], ["1"]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :multiset, row: 0)
    end

    it "matches floats on both sides of zero that are within the absolute tolerance" do
      verdict = compare(result([FLOAT8], [["1e-13"], ["5"]]), result([FLOAT8], [["5"], ["-1e-13"]]))

      expect(verdict.match?).to be(true)
    end

    it "matches a chain of floats that are each within tolerance of their partner" do
      verdict = compare(result([FLOAT8], [["1"], ["1.0000000009"]]),
                        result([FLOAT8], [["1.0000000018"], ["1.0000000009"]]))

      expect(verdict.match?).to be(true)
    end

    it "matches empty results" do
      expect(compare(result([INT4], []), result([INT4], [])).match?).to be(true)
    end
  end

  describe "ordered mode" do
    it "matches the same rows in the same order" do
      verdict = compare(result([INT4], [["1"], ["2"]]), result([INT4], [["1"], ["2"]]), mode: :ordered)

      expect(verdict_fields(verdict)).to eq(match: true, mode: :ordered, rule: nil,
                                            expected_rows: 2, actual_rows: 2, row: nil, column: nil)
    end

    it "is a value mismatch at the first differing row and column when the order differs" do
      verdict = compare(result([TEXT, INT4], [%w[a 1], %w[a 2]]), result([TEXT, INT4], [%w[a 2], %w[a 1]]),
                        mode: :ordered)

      expect(verdict_fields(verdict)).to include(match: false, rule: :value, row: 0, column: 1)
    end

    it "is a row_count mismatch when the counts differ" do
      verdict = compare(result([INT4], [["1"]]), result([INT4], [["1"], ["2"]]), mode: :ordered)

      expect(verdict_fields(verdict)).to include(match: false, rule: :row_count, expected_rows: 1, actual_rows: 2)
    end
  end

  describe "with_ties mode" do
    it "compares as a multiset" do
      match = compare(result([INT4], [["1"], ["2"]]), result([INT4], [["2"], ["1"]]), mode: :with_ties)
      mismatch = compare(result([INT4], [["1"], ["2"]]), result([INT4], [["2"], ["3"]]), mode: :with_ties)

      expect([match.match?, match.mode]).to eq([true, :with_ties])
      expect(verdict_fields(mismatch)).to include(match: false, rule: :multiset, row: 1)
    end
  end

  describe "subset mode" do
    let(:full) { result([INT4, TEXT], [%w[1 a], %w[2 b], %w[3 c], %w[2 b]]) }

    def subset(actual, expected_count: 2) = compare(full, actual, mode: :subset, expected_count:)

    it "matches any sub-multiset of the full result with the expected count" do
      first = subset(result([INT4, TEXT], [%w[1 a], %w[2 b]]))
      other = subset(result([INT4, TEXT], [%w[3 c], %w[2 b]]))

      expect(verdict_fields(first)).to eq(match: true, mode: :subset, rule: nil,
                                          expected_rows: 2, actual_rows: 2, row: nil, column: nil)
      expect(other.match?).to be(true)
    end

    it "matches a row as many times as the full result has it" do
      expect(subset(result([INT4, TEXT], [%w[2 b], %w[2 b]])).match?).to be(true)
    end

    it "is a subset mismatch when a row appears more often than in the full result" do
      verdict = subset(result([INT4, TEXT], [%w[1 a], %w[1 a]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :subset, row: 1)
    end

    it "is a subset mismatch at a candidate row that isn't in the full result" do
      verdict = subset(result([INT4, TEXT], [%w[1 a], %w[4 d]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :subset, row: 1)
    end

    it "is a row_count mismatch when the candidate returns other than the expected count" do
      verdict = subset(result([INT4, TEXT], [%w[1 a]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :row_count, expected_rows: 2, actual_rows: 1)
    end

    it "uses the float tolerance" do
      full = result([FLOAT8], [["1"], ["2"], ["3"]])
      inside = compare(full, result([FLOAT8], [["3.0000000001"]]), mode: :subset, expected_count: 1)
      outside = compare(full, result([FLOAT8], [["3.0001"]]), mode: :subset, expected_count: 1)

      expect([inside.match?, outside.rule]).to eq([true, :subset])
    end

    it "needs an expected_count" do
      expect { compare(full, full, mode: :subset) }.to raise_error(ArgumentError, /expected_count/)
    end
  end

  describe "values" do
    it "treats NULL as equal to NULL and unequal to anything else" do
      nulls = compare(result([TEXT], [[nil]]), result([TEXT], [[nil]]), mode: :ordered)
      empty = compare(result([TEXT], [[nil]]), result([TEXT], [[""]]), mode: :ordered)
      float = compare(result([FLOAT8], [[nil]]), result([FLOAT8], [["0"]]), mode: :ordered)

      expect([nulls.match?, empty.rule, float.rule]).to eq([true, :value, :value])
    end

    it "compares text exactly, even when it looks like a float" do
      verdict = compare(result([TEXT], [["1"]]), result([TEXT], [["1.0000000001"]]), mode: :ordered)

      expect(verdict.rule).to eq(:value)
    end

    it "compares integers exactly" do
      verdict = compare(result([INT8], [["1000000000000"]]), result([INT8], [["1000000000001"]]), mode: :ordered)

      expect(verdict.rule).to eq(:value)
    end

    describe "numeric" do
      def numerics(expected, actual)
        compare(result([NUMERIC], [[expected]]), result([NUMERIC], [[actual]]), mode: :ordered).match?
      end

      it "compares by value, so the printed scale doesn't matter" do
        expect([numerics("1.0", "1.00"), numerics("1", "1.000"), numerics("-0.00", "0"), numerics("0.50", "0.5")])
          .to eq([true, true, true, true])
      end

      it "compares exactly, with no tolerance" do
        expect([numerics("1.0", "1.0000000000001"), numerics("1", "10"), numerics("100", "1"),
                numerics("-1", "1"), numerics("0.1", "0.01")]).to eq([false, false, false, false, false])
      end

      it "treats NaN and the infinities as equal only to themselves" do
        expect([numerics("NaN", "NaN"), numerics("Infinity", "Infinity"), numerics("NaN", "0"),
                numerics("Infinity", "-Infinity")]).to eq([true, true, false, false])
      end

      it "matches by value in a multiset too" do
        verdict = compare(result([NUMERIC], [["1.10"], ["2"]]), result([NUMERIC], [["2.000"], ["1.1"]]))

        expect(verdict.match?).to be(true)
      end
    end

    describe "float tolerance" do
      it "is a relative 1e-9" do
        expect([floats("1", "1.0000000009").match?, floats("1", "1.0000000011").match?,
                floats("1000000", "1000000.0009").match?, floats("1000000", "1000000.0011").match?,
                floats("-1", "-1.0000000009").match?, floats("-1", "-1.0000000011").match?])
          .to eq([true, false, true, false, true, false])
      end

      it "is an absolute 1e-12 near zero" do
        expect([floats("0", "9e-13").match?, floats("0", "1.1e-12").match?,
                floats("5e-13", "-4e-13").match?, floats("6e-13", "-6e-13").match?])
          .to eq([true, false, true, false])
      end

      it "treats NaN as equal to NaN and infinities as equal only to themselves" do
        expect([floats("NaN", "NaN").match?, floats("Infinity", "Infinity").match?,
                floats("-Infinity", "-Infinity").match?, floats("Infinity", "-Infinity").match?,
                floats("NaN", "0").match?, floats("Infinity", "1.7976931348623157e+308").match?])
          .to eq([true, true, true, false, false, false])
      end

      it "treats -0 as equal to 0" do
        expect(floats("-0", "0").match?).to be(true)
      end

      it "applies to float4 too" do
        expect([floats("1", "1.0000000009", type: FLOAT4).match?, floats("1", "1.1", type: FLOAT4).match?])
          .to eq([true, false])
      end

      it "doesn't overflow on the largest finite values" do
        expect(floats("1.7976931348623157e+308", "-1.7976931348623157e+308").match?).to be(false)
      end
    end
  end

  describe "trust boundary" do
    let(:types) { [TEXT, FLOAT8, NUMERIC] }
    let(:expected) { result(types, [[sentinel, "1", "1"], [sentinel, "2", "2"]]) }

    let(:mismatches) do
      other = result(types, [["#{sentinel}-other", "1", "1"], [sentinel, "3", "2"]])
      [
        compare(expected, other),
        compare(expected, other, mode: :ordered),
        compare(expected, other, mode: :subset, expected_count: 2),
        compare(expected, result(types, [[sentinel, "1", "1"]]), mode: :ordered),
        compare(expected, result([TEXT], [[sentinel]])),
        compare(expected, result([TEXT, TEXT, NUMERIC], [[sentinel, sentinel, "1"]]))
      ]
    end

    it "keeps no row value in any verdict" do
      expect(mismatches.map(&:rule)).to eq(%i[multiset value subset row_count column_count column_types])
      mismatches.each do |verdict|
        expect(verdict.inspect).not_to include(sentinel)
        expect(verdict.to_h.to_s).not_to include(sentinel)
        expect(verdict.to_h.values).to all(satisfy { |v| [true, false, nil].include?(v) || v.is_a?(Symbol) || v.is_a?(Integer) })
      end
    end

    it "the check catches a sentinel when one is planted" do
      expect(expected.inspect).to include(sentinel)
      expect(expected.to_h.to_s).to include(sentinel)
    end

    it "refuses a verdict field that isn't a count, a position, or a known symbol" do
      fields = { match: false, mode: :multiset, rule: :value, expected_rows: 1, actual_rows: 1, row: 0, column: 0 }
      planted = [{ row: sentinel }, { column: sentinel }, { expected_rows: sentinel }, { actual_rows: -1 },
                 { rule: sentinel.to_sym }, { mode: sentinel.to_sym }, { match: sentinel }]

      planted.each do |change|
        expect { described_class::Verdict.new(**fields, **change) }
          .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(sentinel) }
      end
      expect(described_class::Verdict.new(**fields).row).to eq(0)
    end

    it "keeps row values out of its argument errors" do
      bad = [
        -> { described_class.compare(expected, [[sentinel]], mode: :multiset) },
        -> { described_class.compare(expected, expected, mode: sentinel.to_sym) },
        -> { described_class.compare(expected, expected, mode: :subset, expected_count: sentinel) }
      ]
      bad.each do |call|
        expect { call.call }.to raise_error(ArgumentError) { |e| expect(e.message).not_to include(sentinel) }
      end
    end
  end
end
