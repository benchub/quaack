# frozen_string_literal: true

require "quaack/enclave/result_comparison"

# The precise check for a tie at a LIMIT or OFFSET cut, over rows built by
# hand. Each row is one letter, its own key. result_comparison_postgres_spec.rb
# runs it against Postgres.
RSpec.describe Quaack::Enclave::ResultComparison::CutTies do
  def key = ->(row) { row }
  def contained = ->(big, small) { small.tally.all? { |row, n| big.count(row) >= n } }

  def layout(ascending, descending, cut, offset)
    described_class.layout(full: [ascending.chars, descending.chars], cut: cut.map(&:chars), offset:, key:)
  end

  describe ".layout" do
    it "splits the full result into tie groups where the two runs' prefixes hold the same rows" do
      # b and c tie on the query's keys, so the descending run reverses them.
      expect(layout("abcd", "acbd", %w[ab ac], 0).blocks).to eq([0...1, 1...3, 3...4])
    end

    it "finds the window the cut keeps, from the offset" do
      expect(layout("abcd", "acbd", %w[bc cb], 1).window).to eq(1...3)
    end

    it "finds the window when the offset isn't known, if only one fits" do
      expect(layout("abcd", "acbd", %w[c b], nil).window).to eq(2...3)
    end

    it "is nil when more than one window fits and the offset isn't known" do
      expect([layout("aab", "aab", %w[a a], nil), layout("aab", "aab", %w[a a], 1)&.window]).to eq([nil, 1...2])
    end

    it "is nil when the cut runs aren't the full runs' rows at the offset" do
      expect([layout("abcd", "acbd", %w[ab ac], 1), layout("abcd", "acbd", %w[ab ab], 0),
              layout("abcd", "acbd", %w[abcde acbde], 0)]).to eq([nil, nil, nil])
    end

    it "is nil when the two full runs don't hold the same rows" do
      expect(layout("abcd", "abce", %w[a a], 0)).to be_nil
    end

    # A real tie comes back exactly reversed. bca against abc holds the
    # same rows only at the end, but isn't abc reversed.
    it "is nil when a group isn't the other run's group reversed" do
      expect(layout("abc", "bca", %w[a b], 0)).to be_nil
    end

    it "splits equal rows into groups of one, since their order can't matter" do
      expect(layout("aab", "aab", %w[aa aa], 0).blocks).to eq([0...1, 1...2, 2...3])
    end
  end

  describe ".wrong_row" do
    let(:original) { layout("abcd", "acbd", %w[ab ac], 0) }

    it "is nil for rows the original could return: the rows before the tie, then rows from it" do
      expect([described_class.wrong_row(original, %w[a b], contained:),
              described_class.wrong_row(original, %w[a c], contained:)]).to eq([nil, nil])
    end

    it "is the first row of the first group whose rows aren't drawn from it" do
      expect([described_class.wrong_row(original, %w[a d], contained:),
              described_class.wrong_row(original, %w[b a], contained:),
              described_class.wrong_row(original, %w[d d], contained:)]).to eq([1, 0, 0])
    end

    it "lets rows within a group come in any order, but not more of a row than the group holds" do
      wide = layout("abbcd", "acbbd", %w[abbc acbb], 0)

      expect([described_class.wrong_row(wide, %w[a c b b], contained:),
              described_class.wrong_row(wide, %w[a b c c], contained:)]).to eq([nil, 1])
    end

    it "checks rows before a group that the window starts inside" do
      offset = layout("abcd", "acbd", %w[cd bd], 2)

      expect([described_class.wrong_row(offset, %w[b d], contained:),
              described_class.wrong_row(offset, %w[d d], contained:)]).to eq([nil, 0])
    end
  end

  describe ".covers?" do
    let(:original) { layout("abcd", "acbd", %w[ab ac], 0) }

    def covers?(candidate) = described_class.covers?(original, candidate, contained:)

    it "holds when the candidate's groups are the original's" do
      expect(covers?(layout("abcd", "acbd", %w[ab ac], 0))).to be(true)
    end

    it "holds when the candidate orders a group the original leaves tied" do
      expect(covers?(layout("abcd", "abcd", %w[ab ab], 0))).to be(true)
    end

    # The candidate ties x with b and c. Its two runs keep b and c, but
    # without a tiebreaker it could keep x.
    it "fails when a group the candidate cuts holds a row the original's group doesn't" do
      expect(covers?(layout("abxcd", "acxbd", %w[ab ac], 0))).to be(false)
    end

    it "fails when a candidate's group spans two of the original's" do
      expect(covers?(layout("abc", "bac", %w[ab ba], 0))).to be(false)
    end

    # The original keeps two of b, c, and e, then d. The candidate's runs
    # keep e, b, then c, but it could keep c, b, there instead.
    it "lends a candidate's group to each of the original's groups it meets" do
      offset_original = layout("bced", "ecbd", %w[ced cbd], 1)
      candidate = layout("ebcd", "ecbd", %w[ebc ecb], 0)

      expect(described_class.covers?(offset_original, candidate, contained:)).to be(false)
    end

    it "fails when the candidate keeps another number of rows" do
      expect(covers?(layout("abcd", "acbd", %w[abc acb], 0))).to be(false)
    end

    it "maps the candidate's window onto the original's, whatever each one's offset" do
      offset_original = layout("abcd", "acbd", %w[bc cb], 1)
      candidate = layout("bcd", "cbd", %w[bc cb], 0)

      expect(described_class.covers?(offset_original, candidate, contained:)).to be(true)
    end
  end
end
