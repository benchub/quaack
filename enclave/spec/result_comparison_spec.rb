# frozen_string_literal: true

require "quaack/enclave/result_comparison"

# How step 9d reads the original query to pick a comparison mode, and the
# queries it builds. result_comparison_postgres_spec.rb runs them.
RSpec.describe Quaack::Enclave::ResultComparison do
  let(:sentinel) { "SENTINEL-9d20b4" }

  def shape(sql) = described_class::Shape.parse(sql, :original)

  describe "Shape#mode" do
    {
      "SELECT a FROM t" => :multiset,
      "SELECT DISTINCT a FROM t" => :multiset,
      "SELECT a FROM t UNION SELECT a FROM u" => :multiset,
      "SELECT a FROM t WHERE a IN (SELECT a FROM u ORDER BY a LIMIT 3)" => :multiset,
      "SELECT a FROM (SELECT a FROM t ORDER BY a) s" => :multiset,
      "SELECT a FROM t LIMIT 5" => :subset,
      "SELECT a FROM t OFFSET 2" => :subset,
      "SELECT a FROM t LIMIT ALL" => :subset,
      "SELECT a FROM t FETCH FIRST 3 ROWS ONLY" => :subset,
      "SELECT a FROM t UNION ALL SELECT a FROM u LIMIT 2" => :subset,
      "SELECT a FROM t ORDER BY a" => :ordered,
      "SELECT a FROM t ORDER BY a LIMIT 5 OFFSET 2" => :ordered,
      "SELECT a FROM t UNION SELECT a FROM u ORDER BY 1" => :ordered,
      "WITH w AS (SELECT a FROM t) SELECT a FROM w ORDER BY a" => :ordered,
      "SELECT a FROM t ORDER BY a FETCH FIRST 3 ROWS WITH TIES" => :with_ties
    }.each do |sql, mode|
      it "is #{mode} for #{sql}" do
        expect(shape(sql).mode).to eq(mode)
      end
    end
  end

  describe "Shape#ordered?" do
    it "is true only for a top-level ORDER BY" do
      expect([shape("SELECT a FROM t ORDER BY a").ordered?, shape("SELECT a FROM t LIMIT 1").ordered?,
              shape("SELECT a FROM (SELECT a FROM t ORDER BY a) s").ordered?]).to eq([true, false, false])
    end
  end

  describe "Shape#without_limit" do
    it "drops the top-level LIMIT and OFFSET and keeps any inside" do
      sql = "SELECT a FROM t WHERE a IN (SELECT a FROM u LIMIT 3) LIMIT 5 OFFSET 2"

      expect(shape(sql).without_limit).to eq("SELECT a FROM t WHERE a IN (SELECT a FROM u LIMIT 3)")
    end

    it "drops FETCH FIRST" do
      expect(shape("SELECT a FROM t FETCH FIRST 3 ROWS ONLY").without_limit).to eq("SELECT a FROM t")
    end
  end

  describe "Shape#with_tiebreaker" do
    it "appends the output positions to the ORDER BY and keeps the LIMIT" do
      sql = shape("SELECT a, b, c FROM t ORDER BY b DESC LIMIT 5").with_tiebreaker([1, 3])

      expect(sql).to eq("SELECT a, b, c FROM t ORDER BY b DESC, 1, 3 LIMIT 5")
    end

    it "sorts the tiebreaker DESC NULLS FIRST when asked to" do
      sql = shape("SELECT a, b, c FROM t ORDER BY b LIMIT 5").with_tiebreaker([1, 3], descending: true)

      expect(sql).to eq("SELECT a, b, c FROM t ORDER BY b, 1 DESC NULLS FIRST, 3 DESC NULLS FIRST LIMIT 5")
    end

    it "works on a set operation" do
      sql = shape("SELECT a FROM t UNION SELECT a FROM u ORDER BY 1").with_tiebreaker([1])

      expect(sql).to eq("SELECT a FROM t UNION SELECT a FROM u ORDER BY 1, 1")
    end

    it "leaves the query alone for no positions" do
      expect(shape("SELECT a FROM t ORDER BY a").with_tiebreaker([])).to eq("SELECT a FROM t ORDER BY a")
    end

    it "doesn't change the parse it came from" do
      parsed = shape("SELECT a FROM t ORDER BY a LIMIT 1")
      parsed.with_tiebreaker([1])

      expect([parsed.without_limit, parsed.with_tiebreaker([])])
        .to eq(["SELECT a FROM t ORDER BY a", "SELECT a FROM t ORDER BY a LIMIT 1"])
    end
  end

  describe "Shape#probe" do
    it "wraps the query to return its columns and no rows" do
      expect(shape("SELECT a FROM t ORDER BY a LIMIT 3").probe)
        .to eq("SELECT * FROM (SELECT a FROM t ORDER BY a LIMIT 3) quaack_probe LIMIT 0")
    end
  end

  describe "tiebreaker_positions" do
    it "gives the 1-based positions of the columns whose types btree can order" do
      # int4, json, text, xml, float8[], point, numeric
      expect(described_class.tiebreaker_positions([23, 114, 25, 142, 1022, 600, 1700])).to eq([1, 3, 5, 7])
    end
  end

  describe "errors" do
    it "refuses SQL that doesn't parse, and keeps none of it" do
      expect { described_class::Shape.parse("SELECT '#{sentinel}' FROM", :candidate) }
        .to raise_error(described_class::Error) { |e|
          expect([e.rule, e.query, e.cause]).to eq([:unparsable, :candidate, nil])
          expect(e.message).to eq("a query for the result comparison couldn't be parsed")
          expect(e.inspect).not_to include(sentinel)
        }
    end

    it "refuses anything but one SELECT, and keeps none of it" do
      ["SELECT '#{sentinel}'; SELECT 1", "DELETE FROM t WHERE a = '#{sentinel}'"].each do |sql|
        expect { described_class::Shape.parse(sql, :original) }
          .to raise_error(described_class::Error) { |e|
            expect([e.rule, e.query]).to eq(%i[not_one_select original])
            expect(e.message).to eq("a query for the result comparison isn't exactly one SELECT")
          }
      end
    end

    it "refuses SQL the enclave's walkers don't support, naming only its shape" do
      ["SELECT a FROM t TABLESAMPLE SYSTEM (10) WHERE a = '#{sentinel}'",
       "SELECT a FROM t WHERE a = '#{sentinel}' FOR UPDATE"].each do |sql|
        expect { described_class::Shape.parse(sql, :candidate) }
          .to raise_error(Quaack::Enclave::SupportedSql::Error) { |e| expect(e.message).not_to include(sentinel) }
      end
    end

    it "the check catches a sentinel when one is planted" do
      expect(PgQuery::ParseError.new("syntax error near '#{sentinel}'", nil, nil, nil).message).to include(sentinel)
    end
  end
end
