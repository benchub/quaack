# frozen_string_literal: true

require "quaack/driver/rewrite_names"

RSpec.describe Quaack::Driver::RewriteNames do
  # A rough syllable count, by vowel groups, to cross-check the counts the
  # lists record. A silent final e, and an -ed that isn't after t or d,
  # don't count; a final consonant-le does.
  def rough_syllables(word)
    groups = word.scan(/[aeiouy]+/).size
    groups -= 1 if word.end_with?("e") && !word.match?(/[^aeiouy]le\z/) && groups > 1
    groups -= 1 if word.match?(/[^td]ed\z/) && groups > 1
    groups
  end

  # Words the rough count gets wrong, each counted by hand.
  let(:rough_misses) { { "cookie" => 2, "graceful" => 2, "kayak" => 2, "lively" => 2, "magpie" => 2 } }

  def words_of(name) = name.split.map(&:downcase)

  def syllables(name)
    adjective, noun = words_of(name)
    described_class::ADJECTIVES.fetch(adjective) + described_class::NOUNS.fetch(noun)
  end

  describe "the word lists" do
    it "holds 200 adjectives and 200 nouns" do
      expect(described_class::ADJECTIVES.size).to eq(200)
      expect(described_class::NOUNS.size).to eq(200)
    end

    it "puts no word in both lists" do
      expect(described_class::ADJECTIVES.keys & described_class::NOUNS.keys).to eq([])
    end

    it "holds only plain lowercase words of one or two syllables" do
      all = described_class::ADJECTIVES.merge(described_class::NOUNS)
      expect(all.keys.grep_v(/\A[a-z]+\z/)).to eq([])
      expect(all.values.uniq.sort).to eq([1, 2])
    end

    it "records the syllable counts a rough count gives, less the words it gets wrong" do
      all = described_class::ADJECTIVES.merge(described_class::NOUNS)
      wrong = all.reject { |word, count| rough_misses.fetch(word) { rough_syllables(word) } == count }
      expect(wrong).to eq({})
    end

    it "lists every hand-counted miss in a list, with a count the rough count doesn't give" do
      all = described_class::ADJECTIVES.merge(described_class::NOUNS)
      expect(rough_misses.reject { |word, count| all[word] == count && rough_syllables(word) != count }).to eq({})
    end

    it "has enough of each kind for many thousands of names" do
      expect(described_class.size).to be >= 10_000
    end
  end

  describe ".name" do
    it "gives an Adjective Noun in title case, of three syllables" do
      names = (1..300).map { described_class.name("20261004T000000Z-0a1b2c3d", it) }
      expect(names).to all(match(/\A[A-Z][a-z]+ [A-Z][a-z]+\z/))
      expect(names.map { syllables(it) }.uniq).to eq([3])
      expect(names.map { words_of(it).first }).to all(satisfy { described_class::ADJECTIVES.key?(it) })
      expect(names.map { words_of(it).last }).to all(satisfy { described_class::NOUNS.key?(it) })
    end

    it "uses both shapes of name: one-syllable adjectives and two-syllable ones" do
      names = (1..300).map { described_class.name("20261004T000000Z-0a1b2c3d", it) }
      expect(names.map { described_class::ADJECTIVES.fetch(words_of(it).first) }.uniq.sort).to eq([1, 2])
    end

    it "always gives the same name for a run and number, in any process" do
      expect(described_class.name("20260926T010203Z-0123abcd", 1)).to eq("Dreamy Wren")
      expect(described_class.name("20260926T010203Z-0123abcd", 2)).to eq("Tawny Crab")
      expect(described_class.name("RUN-1", 1)).to eq("Vivid Cove")
    end

    it "gives a rewrite's name without regard to how many rewrites there are" do
      later = described_class.names("20261004T000000Z-0a1b2c3d", 40)
      expect((1..40).map { described_class.name("20261004T000000Z-0a1b2c3d", it) }).to eq(later)
      expect(described_class.names("20261004T000000Z-0a1b2c3d", 10)).to eq(later.first(10))
    end

    it "gives different runs different names" do
      firsts = (1..20).map { described_class.names("20261004T000000Z-#{it}", 3) }
      expect(firsts.uniq.size).to eq(20)
    end

    it "never repeats a name in a run, down to the last name there is" do
      names = described_class.names("20261004T000000Z-0a1b2c3d", described_class.size)
      expect(names.size).to eq(described_class.size)
      expect(names.uniq.size).to eq(described_class.size)
    end

    it "gives nil past the last name there is" do
      expect(described_class.name("RUN-1", described_class.size + 1)).to be_nil
      expect(described_class.names("RUN-1", described_class.size + 3).size).to eq(described_class.size)
    end
  end

  describe ".label" do
    it "gives a rewrite's store name as Rewrite and its name" do
      expect(described_class.label("RUN-1", "rewrite_1")).to eq("Rewrite Vivid Cove")
    end

    it "gives the number past the last name there is" do
      past = described_class.size + 1
      expect(described_class.label("RUN-1", "rewrite_#{past}")).to eq("Rewrite #{past}")
    end

    it "gives anything else as it is" do
      expect(described_class.label("RUN-1", "original")).to eq("original")
      expect(described_class.label("RUN-1", "rewrite_1x")).to eq("rewrite_1x")
      expect(described_class.label("RUN-1", nil)).to eq("")
    end
  end
end
