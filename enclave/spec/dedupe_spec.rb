# frozen_string_literal: true

require "pp"
require "quaack/enclave/dedupe"

RSpec.describe Quaack::Enclave::Dedupe do
  let(:key_column) { Quaack::Enclave::IndexCandidate::KeyColumn }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }
  let(:customers) { Quaack::Enclave::TableName.new(schema: "public", name: "customers") }
  let(:columns) { %w[id customer_id status kind created_at total note email] }

  def candidate(key, table: orders, sources: [:parse], **)
    Quaack::Enclave::IndexCandidate.new(table:, key:, sources:, **)
  end

  def existing(key, table: orders, **) = candidate(key, table:, sources: [:existing], **)

  def desc(name, nulls: nil) = key_column.new(name:, direction: :desc, nulls:)

  def asc(name, nulls: nil) = key_column.new(name:, direction: :asc, nulls:)

  def statistics(orders_indexes = {}, customers_indexes = {})
    table = lambda do |name, indexes|
      Quaack::Enclave::TableStatistics.new(name:, reltuples: 1000, columns: {}, column_names: columns, indexes:)
    end
    Quaack::Enclave::Statistics.new(tables: [table[orders, orders_indexes], table[customers, customers_indexes]])
  end

  def search(indexes = {}, low_cardinality: [[orders, "status"], [orders, "kind"]], customers_indexes: {})
    described_class.new(statistics: statistics(indexes, customers_indexes), low_cardinality:)
  end

  # Runs one candidate through a fresh search whose only existing index is
  # the given one, and says whether the index covered it.
  def covered?(existing_index, cand)
    s = search({ "the_idx" => existing_index })
    survivors = s.filter([cand])
    s.drops.any? { |d| d.reason == :covered_by_existing } && survivors.empty?
  end

  describe "filter" do
    it "returns every candidate, in order, when nothing covers or repeats them" do
      a = candidate(["customer_id"])
      b = candidate(%w[status created_at], sources: [:plan])

      expect(search.filter([a, b])).to eq([a, b])
    end

    it "returns a frozen array" do
      expect(search.filter([candidate(["customer_id"])])).to be_frozen
    end

    it "refuses anything but an Array of IndexCandidates, without quoting it" do
      s = search
      expect { s.filter("quaack-sentinel") }.to raise_error(ArgumentError, /Array of IndexCandidates/) { |e|
        expect(e.message).not_to include("quaack-sentinel")
      }
      expect { s.filter([candidate(["id"]), "quaack-sentinel"]) }.to raise_error(ArgumentError) { |e|
        expect(e.message).not_to include("quaack-sentinel")
      }
    end

    it "counts every candidate it's given, across calls, whatever happens to it" do
      s = search
      s.filter([candidate(["customer_id"]), candidate(["customer_id"]), candidate(["note"], access_method: :gin)])
      s.filter([candidate(["status"], predicate: "note = 'x'"), candidate(["status"])])

      expect(s.considered).to eq(5)
      expect(s.drops.size + s.set_aside.size + s.proposals.size).to eq(5)
    end

    it "counts only the candidates it actually considered when filter fails" do
      s = search
      expect { s.filter([candidate(["id"]), "quaack-sentinel"]) }.to raise_error(ArgumentError)
      expect(s.considered).to eq(0)

      stranger = Quaack::Enclave::TableName.new(schema: "public", name: "strangers")
      expect { s.filter([candidate(["id"]), candidate(["id"], table: stranger), candidate(["note"])]) }
        .to raise_error(KeyError)
      expect(s.considered).to eq(1)
      expect(s.drops.size + s.set_aside.size + s.proposals.size).to eq(1)
    end

    it "raises KeyError for a candidate on a table with no statistics" do
      other = Quaack::Enclave::TableName.new(schema: "public", name: "nowhere")

      expect { search.filter([candidate(["id"], table: other)]) }.to raise_error(KeyError, /public\.nowhere/)
    end
  end

  describe "construction" do
    it "refuses statistics that aren't a Statistics" do
      expect { described_class.new(statistics: {}, low_cardinality: []) }
        .to raise_error(ArgumentError, /statistics must be a Statistics/)
    end

    it "refuses low_cardinality entries that aren't a TableName and a column name, without quoting them" do
      bad = [[["public.orders", "status"]], [[orders, ""]], [[orders]], ["quaack-sentinel"], "quaack-sentinel"]
      bad.each do |low_cardinality|
        expect { described_class.new(statistics: statistics, low_cardinality:) }
          .to raise_error(ArgumentError, /low_cardinality/) { |e| expect(e.message).not_to include("quaack-sentinel") }
      end
    end
  end

  describe "coverage by an existing index" do
    it "drops a candidate identical to an existing index and records the index by name" do
      index = existing(%w[customer_id created_at])
      s = search({ "orders_customer_created_idx" => index })
      cand = candidate(%w[customer_id created_at])

      expect(s.filter([cand])).to eq([])
      expect(s.drops.size).to eq(1)
      drop = s.drops.first
      expect(drop.reason).to eq(:covered_by_existing)
      expect(drop.candidate).to eq(cand)
      expect(drop.candidate.sources).to eq(Set[:parse])
      expect(drop.covered_by).to eq(described_class::ExistingIndex.new(name: "orders_customer_created_idx",
                                                                       definition: index))
    end

    it "drops a candidate whose key is a leading prefix of an existing btree's key" do
      expect(covered?(existing(%w[customer_id created_at total]), candidate(%w[customer_id created_at]))).to be(true)
      expect(covered?(existing(%w[customer_id created_at total]), candidate(%w[customer_id]))).to be(true)
    end

    it "keeps a candidate whose key isn't a leading prefix" do
      expect(covered?(existing(%w[customer_id created_at]), candidate(%w[created_at]))).to be(false)
      expect(covered?(existing(%w[customer_id created_at]), candidate(%w[created_at customer_id]))).to be(false)
      expect(covered?(existing(%w[customer_id]), candidate(%w[customer_id created_at]))).to be(false)
    end

    it "only looks at the candidate's own table" do
      s = search({}, customers_indexes: { "customers_id_idx" => existing(["id"], table: customers) })

      expect(s.filter([candidate(["id"])])).to eq([candidate(["id"])])
      expect(described_class.covers?(existing(["id"], table: customers), candidate(["id"]))).to be(false)
      expect(described_class.covers?(existing(["id"]), candidate(["id"]))).to be(true)
    end

    it "never counts an existing index that IndexCandidate couldn't represent" do
      s = search({ "orders_lower_note_idx" => nil })

      expect(s.filter([candidate(["note"])])).to eq([candidate(["note"])])
      expect(s.drops).to eq([])
    end

    describe "sort direction and nulls ordering" do
      it "counts a btree prefix read backward: every direction and nulls ordering flipped" do
        index = existing(%w[customer_id created_at total])

        expect(covered?(index, candidate([desc("customer_id"), desc("created_at")]))).to be(true)
        expect(covered?(index, candidate([desc("customer_id")]))).to be(true)
      end

      it "flips nulls ordering too when it reads a prefix backward" do
        index = existing([asc("customer_id", nulls: :first)])

        expect(covered?(index, candidate([desc("customer_id", nulls: :last)]))).to be(true)
        expect(covered?(index, candidate([desc("customer_id", nulls: :first)]))).to be(false)
      end

      it "keeps a candidate whose directions match neither forward nor backward" do
        index = existing(%w[customer_id created_at])

        expect(covered?(index, candidate(["customer_id", desc("created_at")]))).to be(false)
        expect(covered?(index, candidate([desc("customer_id"), "created_at"]))).to be(false)
      end

      it "keeps a candidate that differs only in nulls ordering" do
        expect(covered?(existing(["customer_id"]), candidate([asc("customer_id", nulls: :first)]))).to be(false)
        expect(covered?(existing([asc("customer_id", nulls: :first)]), candidate(["customer_id"]))).to be(false)
      end
    end

    describe "index method" do
      it "keeps a candidate whose method differs from the existing index's" do
        expect(covered?(existing(["created_at"]), candidate(["created_at"], access_method: :brin))).to be(false)
        expect(covered?(existing(["created_at"], access_method: :brin), candidate(["created_at"]))).to be(false)
        expect(covered?(existing(["customer_id"], access_method: :hash), candidate(["customer_id"]))).to be(false)
      end

      it "drops a non-btree candidate only when the existing index has the same method and key" do
        brin = ->(key) { existing(key, access_method: :brin) }

        expect(covered?(brin[["created_at"]], candidate(["created_at"], access_method: :brin))).to be(true)
        expect(covered?(brin[%w[created_at total]], candidate(["created_at"], access_method: :brin))).to be(false)
        expect(covered?(existing(["customer_id"], access_method: :hash),
                        candidate(["customer_id"], access_method: :hash))).to be(true)
      end
    end

    describe "partial indexes" do
      it "keeps a plain candidate that a partial index would otherwise cover" do
        index = existing(%w[customer_id created_at], predicate: "status = 'open'")

        expect(covered?(index, candidate(["customer_id"]))).to be(false)
      end

      it "drops a partial candidate under an existing index with the same predicate" do
        index = existing(%w[customer_id created_at], predicate: "status = 'open'")

        expect(covered?(index, candidate(["customer_id"], predicate: "(status = 'open')"))).to be(true)
      end

      it "keeps a partial candidate under an index with a different predicate, or none" do
        partial = existing(%w[customer_id created_at], predicate: "status = 'open'")

        expect(covered?(partial, candidate(["customer_id"], predicate: "status = 'shipped'"))).to be(false)
        expect(covered?(existing(%w[customer_id]), candidate(["customer_id"], predicate: "status = 'open'")))
          .to be(false)
      end
    end

    describe "unique indexes" do
      it "drops a plain candidate that's a prefix of a unique index" do
        expect(covered?(existing(%w[customer_id created_at], unique: true), candidate(["customer_id"]))).to be(true)
      end

      it "drops a unique candidate only under a unique index with the same key columns" do
        unique = ->(key) { candidate(key, unique: true) }

        expect(covered?(existing(["id"], unique: true), unique[["id"]])).to be(true)
        expect(covered?(existing(["id"]), unique[["id"]])).to be(false)
        expect(covered?(existing(%w[id customer_id], unique: true), unique[["id"]])).to be(false)
      end
    end

    describe "INCLUDE columns" do
      it "counts an INCLUDE column that the existing index has in its key" do
        expect(covered?(existing(%w[customer_id total]), candidate(["customer_id"], include: ["total"]))).to be(true)
      end

      it "counts INCLUDE columns in any order" do
        index = existing(["customer_id"], include: %w[total note])

        expect(covered?(index, candidate(["customer_id"], include: %w[note total]))).to be(true)
        expect(covered?(index, candidate(["customer_id"], include: %w[note]))).to be(true)
      end

      it "keeps a candidate with an INCLUDE column the existing index lacks" do
        index = existing(%w[customer_id created_at], include: ["total"])

        expect(covered?(index, candidate(["customer_id"], include: %w[total note]))).to be(false)
      end

      it "keeps a candidate that needs as a key column what the existing index only INCLUDEs" do
        expect(covered?(existing(["customer_id"], include: ["total"]), candidate(%w[customer_id total]))).to be(false)
      end
    end
  end

  describe "duplicates of an earlier proposal" do
    it "drops a later generator's copy, adds its source to the earlier one, and records both" do
      s = search
      first = candidate(%w[customer_id created_at], sources: [:parse])
      s.filter([first])
      copy = candidate(%w[customer_id created_at], sources: [:plan])

      expect(s.filter([copy])).to eq([])
      expect(s.proposals.map(&:sources)).to eq([Set[:parse, :plan]])
      drop = s.drops.first
      expect(drop.reason).to eq(:duplicate)
      expect(drop.candidate.sources).to eq(Set[:plan])
      expect(drop.covered_by).to eq(first)
      expect(drop.covered_by.sources).to eq(Set[:parse, :plan])
    end

    it "drops a repeat within one generator's output" do
      s = search
      a = candidate(["customer_id"])

      expect(s.filter([a, candidate(["status"]), a])).to eq([a, candidate(["status"])])
      expect(s.drops.map(&:reason)).to eq([:duplicate])
    end

    it "returns the survivors with every source merged so far in that call" do
      s = search
      result = s.filter([candidate(["customer_id"], sources: [:parse]), candidate(["customer_id"], sources: [:plan])])

      expect(result.map(&:sources)).to eq([Set[:parse, :plan]])
    end

    it "keeps a prefix of an earlier proposal, since generator one proposes every prefix on purpose" do
      s = search
      s.filter([candidate(%w[customer_id created_at])])

      expect(s.filter([candidate(["customer_id"], sources: [:plan])])).to eq([candidate(["customer_id"])])
    end

    it "treats INCLUDE columns in another order as a duplicate" do
      s = search
      s.filter([candidate(["id"], include: %w[total note], sources: [:parse])])

      expect(s.filter([candidate(["id"], include: %w[note total], sources: [:plan])])).to eq([])
      expect(s.proposals.map { |p| [p.include, p.sources] }).to eq([[%w[total note], Set[:parse, :plan]]])
      expect(s.drops.map(&:reason)).to eq([:duplicate])
    end

    it "treats a btree read backward as a duplicate, and keeps the first proposal" do
      s = search
      s.filter([candidate(%w[id customer_id], sources: [:parse])])

      expect(s.filter([candidate([desc("id"), desc("customer_id")], sources: [:plan])])).to eq([])
      expect(s.proposals).to eq([candidate(%w[id customer_id])])
      expect(s.proposals.first.sources).to eq(Set[:parse, :plan])
    end

    it "treats a reversed unique btree as a duplicate, but not a partly reversed one" do
      s = search
      s.filter([candidate(%w[id customer_id]), candidate(["id"], unique: true)])

      expect(s.filter([candidate(["id", desc("customer_id")]), candidate([desc("id")])]).size).to eq(2)
      expect(s.filter([candidate([desc("id")], unique: true)])).to eq([])
    end

    it "doesn't treat a unique candidate and a plain one with the same key as duplicates" do
      s = search
      s.filter([candidate(["id"], unique: true)])

      expect(s.filter([candidate(["id"])]).size).to eq(1)
      expect(s.filter([candidate(["customer_id"]), candidate(["customer_id"], unique: true)]).size).to eq(2)
    end

    it "keeps every proposal in order in proposals" do
      s = search
      s.filter([candidate(["customer_id"])])
      s.filter([candidate(["status"], sources: [:plan]), candidate(["customer_id"], sources: [:plan])])

      expect(s.proposals).to eq([candidate(["customer_id"]), candidate(["status"])])
      expect(s.proposals).to be_frozen
    end

    it "returns drops as a frozen array" do
      s = search
      s.filter([candidate(["id"]), candidate(["id"])])

      expect(s.drops.size).to eq(1)
      expect(s.drops).to be_frozen
    end
  end

  describe "partial candidates and low cardinality" do
    it "keeps a partial candidate whose predicate uses only low-cardinality columns" do
      cand = candidate(["customer_id"], predicate: "status = 'open' AND kind <> 'gift'")

      expect(search.filter([cand])).to eq([cand])
    end

    it "drops a partial candidate whose predicate uses a column that isn't low-cardinality" do
      s = search
      cand = candidate(["customer_id"], predicate: "status = 'open' AND email = 'x@example.com'")

      expect(s.filter([cand])).to eq([])
      expect(s.drops.map { |d| [d.reason, d.covered_by] }).to eq([[:partial_not_low_cardinality, nil]])
    end

    it "only counts a column as low-cardinality on its own table" do
      s = search(low_cardinality: [[customers, "status"]])

      expect(s.filter([candidate(["customer_id"], predicate: "status = 'open'")])).to eq([])
    end

    it "drops a partial candidate whose column it can't resolve, such as a qualified one" do
      expect(search.filter([candidate(["customer_id"], predicate: "orders.status = 'open'")])).to eq([])
    end

    it "drops a partial candidate that names a column twice over, such as status.status" do
      expect(search.filter([candidate(["customer_id"], predicate: "status.status = 'open'")])).to eq([])
    end

    # 20260923-36: a predicate with no literal carries no values, so its
    # columns needn't be low-cardinality.
    it "keeps a no-literal partial on any bare column: IS NULL, IS NOT NULL, or a boolean column" do
      ["deleted_at IS NULL", "note IS NOT NULL", "archived", "NOT archived",
       "deleted_at IS NULL AND archived"].each do |predicate|
        expect(search.filter([candidate(["customer_id"], predicate:)]).size).to eq(1), predicate
      end
    end

    it "still drops a no-literal partial that isn't only null tests and boolean columns" do
      ["note = email", "lower(note) IS NULL", "orders.note IS NULL", "note IS NULL OR archived",
       "archived IS TRUE"].each do |predicate|
        expect(search.filter([candidate(["customer_id"], predicate:)])).to eq([]), predicate
      end
    end

    it "still drops a partial with a literal on a column that isn't low-cardinality, and never shows it" do
      sentinel = "quaack-sentinel-n0l1t"
      ["note = '#{sentinel}'", "note IS NULL AND note = '#{sentinel}'"].each do |predicate|
        s = search
        expect(s.filter([candidate(["customer_id"], predicate:)])).to eq([]), predicate
        expect(s.drops.map(&:reason)).to eq([:partial_not_low_cardinality])
        [s.drops.inspect, s.inspect].each { |text| expect(text).not_to include(sentinel) }
      end
    end

    it "finds columns anywhere in the predicate, such as inside a function call" do
      s = search
      expect(s.filter([candidate(["customer_id"], predicate: "lower(note) IS NULL")])).to eq([])
      expect(s.filter([candidate(["customer_id"], predicate: "lower(status) IS NULL")]).size).to eq(1)
    end

    describe "constants" do
      def kept?(predicate)
        s = search(low_cardinality: [[orders, "status"], [orders, "kind"], [orders, "flag"]])
        s.filter([candidate(["customer_id"], predicate:)]).size == 1
      end

      it "keeps a constant compared directly with a low-cardinality column" do
        ["status = 'open'", "'open' = status", "status <> 'open'", "status > 'a'", "status = 'open'::text",
         "status = CAST('open' AS varchar(10))::text", "status IN ('open', 'shipped')",
         "status NOT IN ('open')", "status = ANY('{open,shipped}')", "status = ANY('{open}'::text[])",
         "status = ANY(ARRAY['open', 'shipped'])", "status BETWEEN 'a' AND 'm'", "status LIKE 'op%'",
         "status IS DISTINCT FROM 'open'", "'open' IS DISTINCT FROM status", "status = NULL",
         "kind = 3 OR NOT status = 'open'", "status <> ALL('{a,b}')", "status IS NOT DISTINCT FROM 'open'",
         "status ILIKE 'op%'", "status NOT BETWEEN 'a' AND 'm'", "status BETWEEN SYMMETRIC 'm' AND 'a'",
         "status NOT BETWEEN SYMMETRIC 'm' AND 'a'", "status = 'x'::varchar(10)"].each do |predicate|
          expect(kept?(predicate)).to be(true), predicate
        end
      end

      # A plan prints a varchar column compared with text as
      # (status)::text = 'open'::text, and generator two keeps the casts.
      it "keeps a constant compared with a column under casts" do
        ["status::text = 'open'::text", "(status)::text = ANY('{open,shipped}'::text[])",
         "status::text ~~ 'op%'::text", "status::text >= 'a'::text", "'open'::text = status::text",
         "status::varchar(10)::text = 'open'", "status::text BETWEEN 'a' AND 'm'",
         "status::text IN ('a', 'b')", "status::text COLLATE \"C\" = 'a'::text",
         "(status)::text COLLATE \"C\" ~~ 'a%'::text", "status COLLATE \"C\" IN ('a', 'b')"].each do |predicate|
          expect(kept?(predicate)).to be(true), predicate
        end
      end

      it "keeps a predicate with no constants at all on low-cardinality columns" do
        ["flag", "status IS NULL", "NOT flag", "status = kind", "flag IS TRUE"].each do |predicate|
          expect(kept?(predicate)).to be(true), predicate
        end
      end

      # A plan prints LIKE as ~~, NOT LIKE as !~~, and ILIKE as ~~*.
      it "keeps the comparison operators, including LIKE as a plan prints it" do
        ["status::text ~~ 'op%'::text", "status::text !~~ 'op%'::text", "status::text ~~* 'op%'::text",
         "status::text !~~* 'op%'::text", "status != 'a'", "status <= 'a'", "status < 'a'",
         "status OPERATOR(pg_catalog.=) 'a'", "status OPERATOR(pg_catalog.~~) 'a%'",
         "status <> ALL('{a}')", "status >= ANY('{a}')"].each do |predicate|
          expect(kept?(predicate)).to be(true), predicate
        end
      end

      it "drops a constant used with an operator that isn't a comparison" do
        ["(status || 'bob@x.com') IS NULL", "status || 'bob@x.com' = status", "status = status || 'bob@x.com'",
         "status = ANY(ARRAY[status || 'bob@x.com'])", "(status + 123456789) IS NOT NULL",
         "status -> 'bob@x.com' IS NULL", "(status || 'bob@x.com')::boolean", "status @> 'a'",
         "status @> ANY('{a}')", "status && ALL('{a}')", "status OPERATOR(myschema.=) 'a'",
         "status = 'a' COLLATE \"C\"", "lower(status) COLLATE \"C\" = 'a'"].each do |predicate|
          expect(kept?(predicate)).to be(false), predicate
        end
      end

      it "drops a constant that isn't compared directly with a low-cardinality column" do
        ["'secret' = 'secret'", "status = 'open' OR 'ssn' = 'ssn'", "status = lower('bob@x.com')",
         "lower(status) = 'x'", "true", "status = 'open' AND true", "status || 'x' = 'openx'",
         "status = ANY(ARRAY[lower('a')])", "status IN ('a', lower('b'))", "status BETWEEN lower('a') AND 'm'",
         "(status, kind) = ('a', 'b')", "coalesce(status, 'x') = kind",
         "status = (CASE WHEN flag THEN 'a' ELSE 'b' END)", "NULLIF(status, 'x') IS NULL",
         "lower(status) BETWEEN 'a' AND 'm'", "status = lower('x')::text",
         "status = ANY(ARRAY['open', lower('bob@x.com')])", "lower(status)::text = 'x'",
         "(status || 'a')::text = 'x'", "status = 'x'::mytype('secret')", "status IN ('a'::mytype('secret'))",
         "status::mytype('secret') = 'x'", "status = ANY(ARRAY['a'::mytype('secret')])",
         "status::text BETWEEN 'a'::mytype('secret') AND 'm'"].each do |predicate|
          expect(kept?(predicate)).to be(false), predicate
        end
      end

      it "never shows a dropped constant in the drop record" do
        sentinel = "quaack-sentinel-c0n5t"
        predicates = ["status = 'open' OR '#{sentinel}' = '#{sentinel}'",
                      "status = ANY(ARRAY['open', lower('#{sentinel}')])",
                      "status = 'x'::mytype('#{sentinel}')", "(status || '#{sentinel}') IS NULL",
                      "status = ANY(ARRAY[status || '#{sentinel}'])"]
        predicates.each do |predicate|
          s = search
          s.filter([candidate(["customer_id"], predicate:)])

          expect(s.drops.map(&:reason)).to eq([:partial_not_low_cardinality]), predicate
          expect(s.drops.first.candidate.to_ddl).to include(sentinel)
          [s.drops.inspect, s.drops.pretty_inspect, s.inspect].each { |text| expect(text).not_to include(sentinel) }
        end
      end
    end

    it "drops a partial candidate that isn't low-cardinality even when an existing index matches it" do
      index = existing(["customer_id"], predicate: "email = 'x'")
      s = search({ "orders_x_idx" => index })

      s.filter([candidate(["customer_id"], predicate: "email = 'x'")])
      expect(s.drops.map(&:reason)).to eq([:partial_not_low_cardinality])
    end

    describe "trust boundary" do
      let(:sentinel) { "quaack-sentinel-7f3a" }
      let(:dropped) { candidate(["customer_id"], predicate: "email = '#{sentinel}'") }

      it "never shows a dropped partial's literal in the drop record or the search" do
        s = search
        s.filter([dropped])
        drop = s.drops.first
        expect(drop.candidate.to_ddl).to include(sentinel) # the sentinel is really there

        shown = [drop.inspect, drop.to_s, drop.pretty_inspect, s.drops.inspect, s.drops.pretty_inspect,
                 s.inspect, s.to_s, s.pretty_inspect]
        shown.each { |text| expect(text).not_to include(sentinel) }
      end

      it "never shows the literal in a failed pattern match on a drop record" do
        s = search
        s.filter([dropped])

        expect { s.drops.first => { reason: :nothing } }.to raise_error(NoMatchingPatternError) { |e|
          expect(e.message).not_to include(sentinel)
        }
      end

      it "never shows the literal in an error" do
        other = Quaack::Enclave::TableName.new(schema: "public", name: "nowhere")
        elsewhere = candidate(["customer_id"], table: other, predicate: "email = '#{sentinel}'")

        expect { search.filter([elsewhere]) }.to raise_error(KeyError) { |e|
          expect(e.message).not_to include(sentinel)
        }
        expect { search.filter([dropped, sentinel]) }
          .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(sentinel) }
      end
    end
  end

  describe "methods HypoPG can't model" do
    it "sets GIN, GiST, and SP-GiST candidates aside instead of returning them" do
      s = search
      gin = candidate(["note"], access_method: :gin)
      gist = candidate(["note"], access_method: :gist)
      spgist = candidate(["note"], access_method: :spgist)
      btree = candidate(["note"])

      expect(s.filter([gin, gist, btree, spgist])).to eq([btree])
      expect(s.set_aside).to eq([gin, gist, spgist])
      expect(s.set_aside).to be_frozen
      expect(s.proposals).to eq([btree])
      expect(s.drops).to eq([])
    end

    it "returns btree, BRIN, and hash candidates for testing" do
      s = search
      cands = [candidate(["note"]), candidate(["created_at"], access_method: :brin),
               candidate(["id"], access_method: :hash)]

      expect(s.filter(cands)).to eq(cands)
      expect(s.set_aside).to eq([])
    end

    it "sets aside only what survives the filter" do
      s = search({ "orders_note_gin" => existing(["note"], access_method: :gin) })
      s.filter([candidate(["note"], access_method: :gin),
                candidate(["id"], access_method: :gist, predicate: "email = 'x'")])

      expect(s.set_aside).to eq([])
      expect(s.drops.map(&:reason)).to eq(%i[covered_by_existing partial_not_low_cardinality])
    end

    it "merges a later duplicate's sources into the set-aside candidate" do
      s = search
      s.filter([candidate(["note"], access_method: :gin, sources: [:parse])])
      s.filter([candidate(["note"], access_method: :gin, sources: [:llm])])

      expect(s.set_aside.map(&:sources)).to eq([Set[:parse, :llm]])
      expect(s.drops.map(&:reason)).to eq([:duplicate])
    end
  end

  describe "scope" do
    it "keeps each search's proposals, drops, and set-aside candidates to itself" do
      stats = statistics
      low = [[orders, "status"]]
      first = described_class.new(statistics: stats, low_cardinality: low)
      second = described_class.new(statistics: stats, low_cardinality: low)
      a = candidate(["customer_id"])
      gin = candidate(["note"], access_method: :gin)
      first.filter([a, a, gin])

      expect(second.filter([a])).to eq([a])
      expect(second.drops).to eq([])
      expect(second.set_aside).to eq([])
      expect(second.proposals).to eq([a])
      expect(first.drops.size).to eq(1)
    end
  end
end
