# frozen_string_literal: true

require "quaack/enclave/result_comparison"

# The candidate's check for an original whose two runs keep the same rows,
# over rows built by hand. Each row is one letter, its own key, and each
# pair of runs is [ascending, descending]. result_comparison_postgres_spec.rb
# and production_comparison_postgres_spec.rb run it against Postgres.
RSpec.describe Quaack::Enclave::ResultComparison::Regrouped do
  def key = ->(row) { row }
  def contained = ->(big, small) { small.tally.all? { |row, n| big.count(row) >= n } }

  describe ".check" do
    def check(originals, candidates)
      described_class.check(originals.map(&:chars), candidates.first.chars, key:, contained:) do
        candidates.last.chars
      end
    end

    # b and c tie in the original. The candidate orders them, so its two
    # runs come back the same.
    it "matches a candidate that orders the original's tie its own way, in both runs" do
      expect([check(%w[abcd acbd], %w[abcd abcd]), check(%w[abcd acbd], %w[acbd acbd])]).to eq(%i[match match])
    end

    it "matches a candidate whose own ties fall inside the original's" do
      expect(check(%w[abcde adcbe], %w[abdce adbce])).to eq(:match)
    end

    it "is nil when either run puts a row in another of the original's groups" do
      expect([check(%w[abcd acbd], %w[bacd bacd]), check(%w[abcd acbd], %w[abcd abdc])]).to eq([nil, nil])
    end

    # The candidate ties a with b, which the original orders: its two runs
    # put each first in turn.
    it "is nil when the candidate's own tie spans two of the original's groups" do
      expect(check(%w[abc abc], %w[abc bac])).to be_nil
    end

    it "is nil for other rows, or another number of them" do
      expect([check(%w[abcd acbd], %w[abxd axbd]), check(%w[abcd acbd], %w[abc acb]),
              check(%w[abcd acbd], %w[abcdd acbdd])]).to eq([nil, nil, nil])
    end

    it "is nil when the original's runs don't split into reversed groups" do
      expect(check(%w[abc bca], %w[abc abc])).to be_nil
    end

    # Each run holds the original's group, but bca isn't abc reversed, so
    # the runs can't show where the candidate's ties are.
    it "refuses a candidate whose runs fit but don't split into reversed groups" do
      expect(check(%w[abc cba], %w[abc bca])).to eq(:unsupported_order)
    end

    it "asks for the candidate's descending run only once its ascending run fits" do
      asked = []
      ask = lambda do |ascending|
        described_class.check(%w[abcd acbd].map(&:chars), ascending.chars, key:, contained:) do
          asked << ascending
          %w[a c b d]
        end
      end

      expect([ask.call("bacd"), ask.call("abcd"), asked]).to eq([nil, :match, %w[abcd]])
    end
  end

  # A source over runs given as strings, which records the runs it's asked
  # for. A run mismatches when it isn't the original's, as :value.
  let(:runs_class) do
    Struct.new(:runs, :asked) do
      def run(descending) = (asked << descending) && runs.fetch(descending ? 1 : 0)
      def mismatch(original, run) = (:value unless original == run)
      def rows(run) = run.chars
      def key(row) = row
      def contained?(big, small) = small.tally.all? { |row, n| big.count(row) >= n }
    end
  end

  describe ".tiebroken" do
    def tiebroken(originals, candidates)
      source = runs_class.new(candidates, [])
      [described_class.tiebroken(originals, source), source.asked]
    end

    it "matches row for row first" do
      expect(tiebroken(%w[abcd acbd], %w[abcd acbd])).to eq([:match, [false, true]])
    end

    it "matches group by group when a run fails row for row" do
      expect([tiebroken(%w[abcd acbd], %w[abcd abcd]), tiebroken(%w[abcd acbd], %w[acbd acbd])])
        .to eq([[:match, [false, true]], [:match, [false, true]]])
    end

    it "gives the row-for-row mismatch when the runs don't fit, without the descending run if the ascending fails" do
      expect([tiebroken(%w[abcd acbd], %w[bacd bacd]), tiebroken(%w[abcd acbd], %w[abcd abdc])])
        .to eq([[:value, [false]], [:value, [false, true]]])
    end

    it "refuses runs that fit but can't show the candidate's ties" do
      expect(tiebroken(%w[abc cba], %w[abc bca]).first).to eq(:unsupported_order)
    end
  end
end
