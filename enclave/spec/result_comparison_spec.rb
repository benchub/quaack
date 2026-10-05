# frozen_string_literal: true

require "quaack/enclave/result_comparison"

# How fixture-compare reads the original query to pick a comparison mode, and the
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

  describe "Tiebreaker.positions" do
    it "gives the 1-based positions of the columns btree orders and the comparator reads faithfully" do
      # int4, json, text, xml, int4[], point, numeric, float8, bpchar
      expect(described_class::Tiebreaker.positions([23, 114, 25, 142, 1007, 600, 1700, 701, 1042]))
        .to eq([1, 3, 5, 7, 8, 9])
    end

    # Each prints btree-equal values differently: '1 day' and '24 hours',
    # {"a": 1.0} and {"a": 1.00}, or an element's scale or padding.
    it "leaves out interval, jsonb, and arrays of numeric, floats, bpchar, interval, or jsonb" do
      expect(described_class::Tiebreaker.positions([1186, 3802, 1231, 1021, 1022, 1014, 1187, 3807])).to eq([])
    end

    it "adds the catalog's orderable types" do
      expect(described_class::Tiebreaker.positions([99_999, 114, 23], [99_999])).to eq([1, 3])
    end
  end

  describe "Shape#cut?" do
    {
      "SELECT a FROM t ORDER BY a" => false,
      "SELECT a FROM (SELECT a FROM t ORDER BY a LIMIT 1) s ORDER BY a" => false,
      "SELECT a FROM t ORDER BY a LIMIT 1" => true,
      "SELECT a FROM t ORDER BY a OFFSET 1" => true,
      "SELECT DISTINCT ON (a) a, b FROM t ORDER BY a" => true,
      "SELECT DISTINCT a FROM t ORDER BY a" => true,
      "SELECT a FROM t UNION SELECT a FROM u ORDER BY 1" => true,
      "SELECT a FROM t EXCEPT SELECT a FROM u ORDER BY 1" => true,
      "SELECT a FROM t UNION ALL SELECT a FROM u ORDER BY 1" => false
    }.each do |sql, cut|
      it "is #{cut} for #{sql}" do
        expect(shape(sql).cut?).to eq(cut)
      end
    end
  end

  # Each builder deparses a changed tree. pg_query's deparser leaves out
  # parentheses a query needs, so each goes through Deparse's guard.
  describe "the round-trip guard" do
    let(:grouped) { "SELECT id FROM t WHERE (a OR b) IS NULL ORDER BY id LIMIT 5" }

    it "keeps the parentheses a query needs in every builder" do
      built = [shape(grouped).without_limit, shape(grouped).with_tiebreaker([1]), shape(grouped).probe]

      expect(built).to eq([
                            "SELECT id FROM t WHERE (a OR b) IS NULL ORDER BY id",
                            "SELECT id FROM t WHERE (a OR b) IS NULL ORDER BY id, 1 LIMIT 5",
                            "SELECT * FROM (#{grouped}) quaack_probe LIMIT 0"
                          ])
    end

    # The deparser writes 't'::boolean as true, which parses to a
    # different tree.
    it "refuses a query the deparser would change, in every builder, and keeps none of it" do
      parsed = described_class::Shape.parse(
        "SELECT a FROM t WHERE a = '#{sentinel}' AND 't'::boolean ORDER BY a LIMIT 1", :candidate
      )

      [-> { parsed.without_limit }, -> { parsed.with_tiebreaker([1]) }, -> { parsed.probe }].each do |build|
        expect(&build).to raise_error(described_class::Error) { |e|
          expect([e.rule, e.query, e.cause]).to eq([:deparse_mismatch, :candidate, nil])
          expect(e.message).to eq("pg_query's deparser would change a query for the result comparison")
          expect(e.inspect).not_to include(sentinel)
        }
      end
    end
  end

  # rewrite-test compares the same two queries over every scenario and
  # retry. Deparsing each time was most of its garbage (task 20261004-23).
  describe "deparsing once per query" do
    # Shapes are kept across examples, so each example's SQL names a table
    # of its own.
    let(:table) { "t_#{RSpec.current_example.metadata[:scoped_id].tr(":", "_")}" }
    let(:sql) { "SELECT id FROM #{table} WHERE a = 1 ORDER BY id LIMIT 5" }

    # Each example starts with nothing kept, so what earlier examples left
    # can't decide when it's full.
    before do
      described_class::Shape.instance_variable_get(:@kept).clear
      allow(Quaack::Enclave::Deparse).to receive(:faithfully).and_call_original
    end

    it "keeps a query it's asked for again when it's full, rather than forgetting everything" do
      shape(sql).probe
      (described_class::Shape::KEPT - 1).times { |i| shape("SELECT #{i} FROM #{table}_other").mode }
      shape(sql).probe

      expect(Quaack::Enclave::Deparse).to have_received(:faithfully).once
    end

    it "builds each query once for the same SQL, however many times it's asked" do
      built = Array.new(3) do
        parsed = shape(sql)
        [parsed.without_limit, parsed.with_tiebreaker([1]), parsed.with_tiebreaker([1], descending: true), parsed.probe]
      end

      expect(built.uniq).to eq([[
                                 "SELECT id FROM #{table} WHERE a = 1 ORDER BY id",
                                 "SELECT id FROM #{table} WHERE a = 1 ORDER BY id, 1 LIMIT 5",
                                 "SELECT id FROM #{table} WHERE a = 1 ORDER BY id, 1 DESC NULLS FIRST LIMIT 5",
                                 "SELECT * FROM (#{sql}) quaack_probe LIMIT 0"
                               ]])
      expect(Quaack::Enclave::Deparse).to have_received(:faithfully).exactly(4).times
    end

    it "forgets what it kept once it holds #{described_class::Shape::KEPT} queries, so it can't grow without bound" do
      shape(sql).probe
      described_class::Shape::KEPT.times { |i| shape("SELECT #{i} FROM #{table}_other").mode }
      shape(sql).probe

      expect(Quaack::Enclave::Deparse).to have_received(:faithfully).with(anything).twice
    end

    it "keeps different tiebreakers apart" do
      parsed = shape(sql)

      expect([parsed.with_tiebreaker([1]), parsed.with_tiebreaker([2]), parsed.with_tiebreaker([1])])
        .to eq(["SELECT id FROM #{table} WHERE a = 1 ORDER BY id, 1 LIMIT 5",
                "SELECT id FROM #{table} WHERE a = 1 ORDER BY id, 2 LIMIT 5",
                "SELECT id FROM #{table} WHERE a = 1 ORDER BY id, 1 LIMIT 5"])
    end

    it "names the query each was parsed as, for the same SQL" do
      bad = "SELECT a FROM #{table} WHERE 't'::boolean ORDER BY a LIMIT 1"

      queries = %i[original candidate original].map do |query|
        described_class::Shape.parse(bad, query).probe
      rescue described_class::Error => e
        e.query
      end

      expect(queries).to eq(%i[original candidate original])
    end
  end

  describe "Shape#collation_names" do
    it "lists every COLLATE clause's collation, at any depth" do
      sql = %(SELECT a COLLATE "Ci", b FROM t WHERE b IN (SELECT c COLLATE pg_catalog."C" FROM u) ORDER BY a)

      expect(shape(sql).collation_names).to eq(%w[Ci C])
    end

    it "is empty with no COLLATE clause" do
      expect(shape("SELECT a FROM t ORDER BY a").collation_names).to eq([])
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
