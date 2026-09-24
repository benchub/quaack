# frozen_string_literal: true

require "quaack/enclave/result_comparator"

# Step 9d's comparator over two results built by hand. See
# result_comparison_postgres_spec.rb for the rules run against Postgres.
RSpec.describe Quaack::Enclave::ResultComparator do
  # Type OIDs.
  def int4 = 23
  def int8 = 20
  def text = 25
  def float4 = 700
  def float8 = 701
  def numeric = 1700

  let(:sentinel) { "SENTINEL-47c1d9" }

  def result(types, rows, columns: types.each_index.map { |i| "c#{i}" })
    Quaack::Enclave::ArenaRunner::Result.new(columns:, types:, rows:)
  end

  def compare(expected, actual, mode: :multiset, **)
    described_class.compare(expected, actual, mode:, **)
  end

  # One-column float8 results, one value each.
  def floats(expected, actual, type: float8)
    compare(result([type], [[expected]]), result([type], [[actual]]), mode: :ordered)
  end

  def verdict_fields(verdict)
    verdict.to_h.slice(:match, :mode, :rule, :expected_rows, :actual_rows, :row, :column)
  end

  describe "columns" do
    it "is a column_count mismatch when the column counts differ" do
      verdict = compare(result([int4], [["1"]]), result([int4, int4], [%w[1 2]]))

      expect(verdict_fields(verdict)).to eq(match: false, mode: :multiset, rule: :column_count,
                                            expected_rows: 1, actual_rows: 1, row: nil, column: nil)
    end

    it "is a column_types mismatch at the first column whose type differs, even int4 against int8" do
      verdict = compare(result([text, int4, int4], [%w[a 1 1]]), result([text, int8, text], [%w[a 1 1]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :column_types, column: 1)
    end

    it "ignores column names" do
      verdict = compare(result([int4], [["1"]], columns: ["id"]), result([int4], [["1"]], columns: ["other"]))

      expect(verdict.match?).to be(true)
    end
  end

  describe "multiset mode" do
    it "matches the same rows in a different order" do
      verdict = compare(result([int4, text], [%w[1 a], %w[2 b], %w[3 c]]),
                        result([int4, text], [%w[3 c], %w[1 a], %w[2 b]]))

      expect(verdict_fields(verdict)).to eq(match: true, mode: :multiset, rule: nil,
                                            expected_rows: 3, actual_rows: 3, row: nil, column: nil)
    end

    it "is a row_count mismatch when the counts differ" do
      verdict = compare(result([int4], [["1"], ["2"]]), result([int4], [["1"]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :row_count, expected_rows: 2, actual_rows: 1)
    end

    it "counts duplicates, so the same rows with different multiplicities don't match" do
      verdict = compare(result([int4], [["1"], ["1"], ["2"]]), result([int4], [["1"], ["2"], ["2"]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :multiset, row: 2)
    end

    it "is a multiset mismatch at the first candidate row with no partner" do
      verdict = compare(result([int4, text], [%w[1 a], %w[2 b]]), result([int4, text], [%w[2 b], %w[1 z]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :multiset, row: 1, column: nil)
    end

    it "matches floats within tolerance in a different order" do
      verdict = compare(result([float8], [["1"], ["2"]]), result([float8], [["2.0000000001"], ["1.0000000001"]]))

      expect(verdict.match?).to be(true)
    end

    it "doesn't match floats outside tolerance" do
      verdict = compare(result([float8], [["1"], ["2"]]), result([float8], [["2.00001"], ["1"]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :multiset, row: 0)
    end

    it "matches floats on both sides of zero that are within the absolute tolerance" do
      verdict = compare(result([float8], [["1e-13"], ["5"]]), result([float8], [["5"], ["-1e-13"]]))

      expect(verdict.match?).to be(true)
    end

    it "matches a chain of floats that are each within tolerance of their partner" do
      verdict = compare(result([float8], [["1"], ["1.0000000009"]]),
                        result([float8], [["1.0000000018"], ["1.0000000009"]]))

      expect(verdict.match?).to be(true)
    end

    it "matches empty results" do
      expect(compare(result([int4], []), result([int4], [])).match?).to be(true)
    end
  end

  describe "ordered mode" do
    it "matches the same rows in the same order" do
      verdict = compare(result([int4], [["1"], ["2"]]), result([int4], [["1"], ["2"]]), mode: :ordered)

      expect(verdict_fields(verdict)).to eq(match: true, mode: :ordered, rule: nil,
                                            expected_rows: 2, actual_rows: 2, row: nil, column: nil)
    end

    it "is a value mismatch at the first differing row and column when the order differs" do
      verdict = compare(result([text, int4], [%w[a 1], %w[a 2]]), result([text, int4], [%w[a 2], %w[a 1]]),
                        mode: :ordered)

      expect(verdict_fields(verdict)).to include(match: false, rule: :value, row: 0, column: 1)
    end

    it "is a row_count mismatch when the counts differ" do
      verdict = compare(result([int4], [["1"]]), result([int4], [["1"], ["2"]]), mode: :ordered)

      expect(verdict_fields(verdict)).to include(match: false, rule: :row_count, expected_rows: 1, actual_rows: 2)
    end
  end

  describe "with_ties" do
    it "isn't a mode compare takes, since it can't check the order" do
      same = result([int4], [["1"]])

      expect { compare(same, same, mode: :with_ties) }.to raise_error(ArgumentError, /mode must be one of/)
    end

    it "is a mode a verdict can name, never as a match" do
      verdict = described_class::Verdict.for(:with_ties, :unsupported_order)

      expect(verdict_fields(verdict)).to include(match: false, mode: :with_ties, rule: :unsupported_order)
    end
  end

  describe "subset mode" do
    let(:full) { result([int4, text], [%w[1 a], %w[2 b], %w[3 c], %w[2 b]]) }

    def subset(actual, expected_count: 2) = compare(full, actual, mode: :subset, expected_count:)

    it "matches any sub-multiset of the full result with the expected count" do
      first = subset(result([int4, text], [%w[1 a], %w[2 b]]))
      other = subset(result([int4, text], [%w[3 c], %w[2 b]]))

      expect(verdict_fields(first)).to eq(match: true, mode: :subset, rule: nil,
                                          expected_rows: 2, actual_rows: 2, row: nil, column: nil)
      expect(other.match?).to be(true)
    end

    it "matches a row as many times as the full result has it" do
      expect(subset(result([int4, text], [%w[2 b], %w[2 b]])).match?).to be(true)
    end

    it "is a subset mismatch when a row appears more often than in the full result" do
      verdict = subset(result([int4, text], [%w[1 a], %w[1 a]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :subset, row: 1)
    end

    it "is a subset mismatch at a candidate row that isn't in the full result" do
      verdict = subset(result([int4, text], [%w[1 a], %w[4 d]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :subset, row: 1)
    end

    it "is a row_count mismatch when the candidate returns other than the expected count" do
      verdict = subset(result([int4, text], [%w[1 a]]))

      expect(verdict_fields(verdict)).to include(match: false, rule: :row_count, expected_rows: 2, actual_rows: 1)
    end

    it "uses the float tolerance" do
      full = result([float8], [["1"], ["2"], ["3"]])
      inside = compare(full, result([float8], [["3.0000000001"]]), mode: :subset, expected_count: 1)
      outside = compare(full, result([float8], [["3.0001"]]), mode: :subset, expected_count: 1)

      expect([inside.match?, outside.rule]).to eq([true, :subset])
    end

    it "needs an expected_count" do
      expect { compare(full, full, mode: :subset) }.to raise_error(ArgumentError, /expected_count/)
    end
  end

  describe "values" do
    it "treats NULL as equal to NULL and unequal to anything else" do
      nulls = compare(result([text], [[nil]]), result([text], [[nil]]), mode: :ordered)
      empty = compare(result([text], [[nil]]), result([text], [[""]]), mode: :ordered)
      float = compare(result([float8], [[nil]]), result([float8], [["0"]]), mode: :ordered)

      expect([nulls.match?, empty.rule, float.rule]).to eq([true, :value, :value])
    end

    it "compares text exactly, even when it looks like a float" do
      verdict = compare(result([text], [["1"]]), result([text], [["1.0000000001"]]), mode: :ordered)

      expect(verdict.rule).to eq(:value)
    end

    it "compares integers exactly" do
      verdict = compare(result([int8], [["1000000000000"]]), result([int8], [["1000000000001"]]), mode: :ordered)

      expect(verdict.rule).to eq(:value)
    end

    describe "bpchar" do
      def bpchar = 1042

      it "ignores trailing spaces, as bpchar's own equality does" do
        pairs = [["a", "a  "], ["a  ", "a"], ["", "  "]]

        expect(pairs.map { |l, r| compare(result([bpchar], [[l]]), result([bpchar], [[r]]), mode: :ordered).match? })
          .to eq([true, true, true])
      end

      it "keeps leading and inner spaces, case, and trailing whitespace that isn't a space" do
        pairs = [["a", " a"], ["a b", "ab"], ["a", "A"], ["a", "a\t"], ["a", "a\n"]]

        expect(pairs.map { |l, r| compare(result([bpchar], [[l]]), result([bpchar], [[r]]), mode: :ordered).match? })
          .to eq([false, false, false, false, false])
      end

      it "ignores trailing spaces in a multiset too" do
        verdict = compare(result([bpchar], [["a"], ["b "]]), result([bpchar], [["b"], ["a  "]]))

        expect(verdict.match?).to be(true)
      end

      it "keeps trailing spaces in text" do
        expect(compare(result([text], [["a"]]), result([text], [["a "]]), mode: :ordered).match?).to be(false)
      end
    end

    describe "numeric" do
      def numerics_equal?(expected, actual)
        compare(result([numeric], [[expected]]), result([numeric], [[actual]]), mode: :ordered).match?
      end

      it "compares by value, so the printed scale doesn't matter" do
        pairs = [%w[1.0 1.00], %w[1 1.000], %w[-0.00 0], %w[0.50 0.5]]

        expect(pairs.map { |pair| numerics_equal?(*pair) }).to eq([true, true, true, true])
      end

      it "compares exactly, with no tolerance" do
        expect([numerics_equal?("1.0", "1.0000000000001"), numerics_equal?("1", "10"), numerics_equal?("100", "1"),
                numerics_equal?("-1", "1"), numerics_equal?("0.1", "0.01")]).to eq([false, false, false, false, false])
      end

      it "treats NaN and the infinities as equal only to themselves" do
        expect([numerics_equal?("NaN", "NaN"), numerics_equal?("Infinity", "Infinity"), numerics_equal?("NaN", "0"),
                numerics_equal?("Infinity", "-Infinity")]).to eq([true, true, false, false])
      end

      it "matches by value in a multiset too" do
        verdict = compare(result([numeric], [["1.10"], ["2"]]), result([numeric], [["2.000"], ["1.1"]]))

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
        expect([floats("1", "1.0000000009", type: float4).match?, floats("1", "1.1", type: float4).match?])
          .to eq([true, false])
      end

      it "doesn't overflow on the largest finite values" do
        expect(floats("1.7976931348623157e+308", "-1.7976931348623157e+308").match?).to be(false)
      end

      # The difference, 7.603000007350e-9, is inside 1e-9 of the larger
      # value, 7.603000007603e-9, and outside 1e-9 of the smaller, 7.603e-9.
      it "is relative to the larger magnitude" do
        expect([floats("7.603", "7.603000007603").match?, floats("7.603000007603", "7.603").match?])
          .to eq([true, true])
      end

      # 1e-12 - 0 is exactly the absolute tolerance in binary too.
      it "includes the boundary itself" do
        expect([floats("0", "1e-12").match?, floats("-1e-12", "0").match?]).to eq([true, true])
      end

      it "refuses float text that isn't a float, and keeps none of it" do
        bad = result([float8], [[sentinel]])

        expect { compare(bad, bad, mode: :ordered) }
          .to raise_error(ArgumentError, "a float column holds text that isn't a float") { |e|
            expect(e.message).not_to include(sentinel)
          }
      end
    end
  end

  describe "trust boundary" do
    let(:types) { [text, float8, numeric] }
    let(:expected) { result(types, [[sentinel, "1", "1"], [sentinel, "2", "2"]]) }

    let(:mismatches) do
      other = result(types, [["#{sentinel}-other", "1", "1"], [sentinel, "3", "2"]])
      [
        compare(expected, other),
        compare(expected, other, mode: :ordered),
        compare(expected, other, mode: :subset, expected_count: 2),
        compare(expected, result(types, [[sentinel, "1", "1"]]), mode: :ordered),
        compare(expected, result([text], [[sentinel]])),
        compare(expected, result([text, text, numeric], [[sentinel, sentinel, "1"]]))
      ]
    end

    it "keeps no row value in any verdict" do
      expect(mismatches.map(&:rule)).to eq(%i[multiset value subset row_count column_count column_types])
      mismatches.each do |verdict|
        expect(verdict.inspect).not_to include(sentinel)
        expect(verdict.to_h.to_s).not_to include(sentinel)
        expect(verdict.to_h.values.map(&:class).uniq - [TrueClass, FalseClass, NilClass, Symbol, Integer]).to eq([])
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
