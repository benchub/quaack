# frozen_string_literal: true

require "pp"
require "pg_query"
require "quaack/enclave/deparse"
require "quaack/enclave/index_candidate"

RSpec.describe Quaack::Enclave::IndexCandidate do
  let(:key_column) { Quaack::Enclave::IndexCandidate::KeyColumn }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "public", name: "orders") }

  def candidate(**overrides)
    described_class.new(table: orders, key: ["customer_id"], sources: [:parse], **overrides)
  end

  # Parses DDL and returns its one IndexStmt, failing unless there's exactly one.
  def index_stmt(ddl)
    stmts = PgQuery.parse(ddl).tree.stmts
    expect(stmts.size).to eq(1), "expected one statement in #{ddl}"
    expect(stmts.first.stmt.node).to eq(:index_stmt), "expected an IndexStmt in #{ddl}"
    stmts.first.stmt.index_stmt
  end

  def elems(nodes)
    nodes.map { |n| n.index_elem.then { |e| [e.name, e.ordering, e.nulls_ordering] } }
  end

  describe "construction" do
    it "turns a bare column name into an ascending key column" do
      expect(candidate.key).to eq([key_column.new(name: "customer_id", direction: :asc, nulls: :last)])
    end

    it "defaults nulls to Postgres's default for each direction" do
      expect(key_column.new(name: "a").nulls).to eq(:last)
      expect(key_column.new(name: "a", direction: :desc).nulls).to eq(:first)
      expect(key_column.new(name: "a", direction: "DESC", nulls: "LAST"))
        .to eq(key_column.new(name: "a", direction: :desc, nulls: :last))
    end

    it "rejects an unknown direction or nulls ordering" do
      expect { key_column.new(name: "a", direction: :up) }.to raise_error(ArgumentError, /direction/)
      expect { key_column.new(name: "a", nulls: :middle) }.to raise_error(ArgumentError, /nulls/)
      expect { key_column.new(name: "") }.to raise_error(ArgumentError, /name/)
    end

    it "defaults the method to btree and normalizes it to a lowercase symbol" do
      expect(candidate.access_method).to eq(:btree)
      expect(candidate(access_method: "GIN").access_method).to eq(:gin)
      expect(candidate(access_method: :my_custom_am).access_method).to eq(:my_custom_am)
    end

    it "rejects a method that isn't a plain identifier" do
      ["btree; drop table x", "two words", "", "1abc"].each do |bad|
        expect { candidate(access_method: bad) }.to raise_error(ArgumentError, /method/), bad.inspect
      end
    end

    it "stores sources as a frozen set of symbols" do
      c = candidate(sources: ["parse", :plan])

      expect(c.sources).to eq(Set[:parse, :plan])
      expect(c.sources).to be_frozen
    end

    it "is deeply frozen" do
      c = candidate(include: ["total"])

      expect([c, c.key, c.include, c.include.first, c.key.first.name]).to all(be_frozen)
    end

    it "freezes its own copies of column names, leaving the caller's strings alone" do
      names = [+"bare", +"keyed", +"included"]
      c = candidate(key: [names[0], key_column.new(name: names[1])], include: [names[2]])
      names.each { |n| n << "_changed" }

      stored = [c.key[0].name, c.key[1].name, c.include[0]]
      expect(stored).to eq(%w[bare keyed included])
      expect(stored).to all(be_frozen)
      expect(names).to all(satisfy { |n| !n.frozen? })
    end

    it "requires non-empty String names in INCLUDE" do
      ["", :total, nil].each do |bad|
        expect { candidate(include: [bad]) }.to raise_error(ArgumentError, /column name/), bad.inspect
      end
    end

    it "keeps the default nulls orderings in a frozen map" do
      expect(key_column::DEFAULT_NULLS).to eq({ asc: :last, desc: :first })
      expect(key_column::DEFAULT_NULLS).to be_frozen
    end

    it "requires a non-empty key" do
      expect { candidate(key: []) }.to raise_error(ArgumentError, /key/)
    end

    it "rejects a column that's in both the key and INCLUDE" do
      expect { candidate(key: %w[a b], include: %w[c b]) }.to raise_error(ArgumentError, /"b"/)
    end

    it "requires a schema-qualified TableName" do
      expect { candidate(table: "orders") }.to raise_error(ArgumentError, /TableName/)
    end

    it "defaults unique to false and accepts only true or false" do
      expect(candidate.unique).to be(false)
      expect(candidate(unique: true).unique).to be(true)
      [nil, "true", 1].each do |bad|
        expect { candidate(unique: bad) }.to raise_error(ArgumentError, /unique/), bad.inspect
      end
    end

    it "refuses unique on any method but btree, which is the only built-in one that supports it" do
      %i[hash gist my_custom_am].each do |method|
        expect { candidate(unique: true, access_method: method) }.to raise_error(ArgumentError, /unique.*btree/)
      end
    end

    it "requires the predicate to be SQL text or nil" do
      expect { candidate(predicate: 1) }.to raise_error(ArgumentError, /predicate/)
      expect { candidate(predicate: "  ") }.to raise_error(ArgumentError, /predicate/)
    end

    it "refuses an empty predicate as SQL that doesn't parse, with no check of its own for blankness" do
      expect { candidate(predicate: "") }.to raise_error(ArgumentError, /predicate doesn't parse as SQL/)
    end
  end

  describe "equality" do
    it "ignores sources, so duplicates collapse in a set and match as hash keys" do
      a = candidate(sources: [:parse])
      b = candidate(sources: [:plan])

      expect(a).to eq(b)
      expect(a).to eql(b)
      expect(a.hash).to eq(b.hash)
      expect(Set[a, b].size).to eq(1)
      expect({ a => :found }[b]).to eq(:found)
    end

    it "is false, not an error, against nil or anything else that isn't a candidate" do
      [nil, "customer_id", candidate.to_h].each do |other|
        expect(candidate == other).to be(false), other.inspect
        expect(candidate.eql?(other)).to be(false), other.inspect
      end
    end

    it "treats an explicit default nulls ordering as the same definition" do
      expect(candidate(key: [key_column.new(name: "customer_id", nulls: :last)])).to eq(candidate)
    end

    it "tells apart candidates whose definitions differ" do
      base = candidate(key: %w[a b], include: ["c"])
      others = [
        candidate(key: %w[b a], include: ["c"]),
        candidate(key: ["a", key_column.new(name: "b", direction: :desc)], include: ["c"]),
        candidate(key: ["a", key_column.new(name: "b", nulls: :first)], include: ["c"]),
        candidate(key: %w[a b], include: ["d"]),
        candidate(key: %w[a b], include: ["c"], access_method: :gist),
        candidate(key: %w[a b], include: ["c"], predicate: "c > 0"),
        candidate(key: %w[a b], include: ["c"], unique: true),
        candidate(key: %w[a b], include: ["c"], table: Quaack::Enclave::TableName.new(schema: "other", name: "orders"))
      ]

      others.each do |other|
        expect(other).not_to eq(base), other.inspect
        expect(other).not_to eql(base), other.inspect
      end
      expect(Set[base, *others].size).to eq(others.size + 1)
      expect([base, *others].map(&:hash).uniq.size).to eq(others.size + 1)
    end
  end

  describe "#merge_sources" do
    it "returns a copy with both candidates' sources and leaves the originals alone" do
      a = candidate(sources: [:parse])
      b = candidate(sources: %i[plan llm])

      merged = a.merge_sources(b)

      expect(merged.sources).to eq(Set[:parse, :plan, :llm])
      expect(merged).to eq(a)
      expect([a.sources, b.sources]).to eq([Set[:parse], Set[:plan, :llm]])
    end

    it "refuses a candidate with a different definition" do
      expect { candidate.merge_sources(candidate(key: ["other"])) }.to raise_error(ArgumentError, /different/)
    end
  end

  describe "#to_ddl" do
    it "renders an unnamed CREATE INDEX" do
      expect(candidate.to_ddl).to eq("CREATE INDEX ON public.orders USING btree (customer_id)")
    end

    it "renders key directions, nulls ordering, INCLUDE, USING, and WHERE, and re-parses to the same parts" do
      c = candidate(
        key: ["status", key_column.new(name: "created_at", direction: :desc),
              key_column.new(name: "id", direction: :asc, nulls: :first)],
        include: %w[total note],
        access_method: :btree,
        predicate: "status = 'shipped' AND deleted_at IS NULL"
      )

      stmt = index_stmt(c.to_ddl)

      expect([stmt.relation.schemaname, stmt.relation.relname]).to eq(%w[public orders])
      expect(stmt.idxname).to eq("")
      expect(stmt.access_method).to eq("btree")
      expect(elems(stmt.index_params)).to eq(
        [["status", :SORTBY_DEFAULT, :SORTBY_NULLS_DEFAULT],
         ["created_at", :SORTBY_DESC, :SORTBY_NULLS_DEFAULT],
         ["id", :SORTBY_DEFAULT, :SORTBY_NULLS_FIRST]]
      )
      expect(stmt.index_including_params.map { |n| n.index_elem.name }).to eq(%w[total note])
      expect(PgQuery.deparse_expr(stmt.where_clause)).to eq("status = 'shipped' AND deleted_at IS NULL")
    end

    it "renders a unique index" do
      expect(candidate(unique: true).to_ddl).to eq("CREATE UNIQUE INDEX ON public.orders USING btree (customer_id)")
    end

    it "renders a desc column with nulls last explicitly" do
      c = candidate(key: [key_column.new(name: "a", direction: :desc, nulls: :last)])

      expect(elems(index_stmt(c.to_ddl).index_params)).to eq([["a", :SORTBY_DESC, :SORTBY_NULLS_LAST]])
    end

    it "renders an unusual method" do
      expect(index_stmt(candidate(access_method: :brin).to_ddl).access_method).to eq("brin")
      expect(index_stmt(candidate(access_method: :my_custom_am).to_ddl).access_method).to eq("my_custom_am")
    end

    it "quotes mixed-case names, reserved words, and names with spaces" do
      c = described_class.new(
        table: Quaack::Enclave::TableName.new(schema: "My Schema", name: "order"),
        key: %w[CustomerId select], include: ["line item"], sources: [:parse]
      )

      ddl = c.to_ddl
      stmt = index_stmt(ddl)

      expect(ddl).to eq(%(CREATE INDEX ON "My Schema"."order" USING btree ("CustomerId", "select") ) +
                        %(INCLUDE ("line item")))
      expect([stmt.relation.schemaname, stmt.relation.relname]).to eq(["My Schema", "order"])
      expect(elems(stmt.index_params).map(&:first)).to eq(%w[CustomerId select])
      expect(stmt.index_including_params.map { |n| n.index_elem.name }).to eq(["line item"])
    end

    # The parser cuts a name to 63 bytes, so this DDL would name a
    # different column. HypoPG would run it, so it's refused instead.
    it "refuses DDL that doesn't parse back to what was built" do
      long = candidate(key: ["c" * 64])
      expect { long.to_ddl }
        .to raise_error(Quaack::Enclave::Deparse::Error) { |e| expect([e.rule, e.cause]).to eq(["deparse_mismatch", nil]) }
    end
  end

  describe "predicates" do
    it "refuses one that isn't a single expression, at construction" do
      ["true; DROP TABLE orders", "a = 1 UNION SELECT 1", "a = 1 ORDER BY 1", "a = 1 LIMIT 1",
       "a = 1) OR (true", "a = = 1"].each do |bad|
        expect { candidate(predicate: bad) }.to raise_error(ArgumentError, /predicate/), bad.inspect
      end
    end

    # pg_query deparses 't'::boolean as true, which parses as another tree.
    it "refuses one pg_query would deparse as a different expression, without quoting it" do
      expect { candidate(predicate: "(status = 'SENTINEL-4e1a') IS NOT DISTINCT FROM 't'::boolean") }
        .to raise_error(ArgumentError, "predicate changes meaning when pg_query deparses it") { |e|
          expect(e.cause).to be_nil
          expect(e.full_message).not_to include("SENTINEL")
        }
    end

    # pg_query deparses a type modifier that isn't a constant as nothing,
    # so the stored predicate would be 'x'::mytype(), which doesn't parse.
    # Dedupe used to meet such a predicate, and dropped it.
    it "refuses one pg_query would deparse to SQL that doesn't parse, without quoting it" do
      expect { candidate(predicate: "status = 'quaack-sentinel-p4rse'::mytype(lower('bob'))") }
        .to raise_error(ArgumentError, "predicate changes meaning when pg_query deparses it") { |e|
          expect(e.cause).to be_nil
          expect(e.full_message).not_to include("quaack-sentinel")
        }
    end

    it "stores the deparsed form, so equality follows it" do
      wrapped = candidate(predicate: "((status = 'open'))")

      expect(wrapped.predicate).to eq("status = 'open'")
      expect(wrapped.predicate).to be_frozen
      expect(wrapped).to eq(candidate(predicate: "status = 'open'"))
    end

    it "refuses parameters, which Postgres can't bind in an index predicate" do
      ["a = $1", "a > 0 AND b = $2"].each do |bad|
        expect { candidate(predicate: bad) }.to raise_error(ArgumentError, /predicate can't use a parameter/), bad
      end
    end

    it "refuses subqueries" do
      ["a IN (SELECT 1)", "EXISTS (SELECT 1)", "a = (SELECT 1)", "a = ANY (SELECT 1)",
       "NOT (b > 0 OR EXISTS (SELECT 1))"]
        .each do |bad|
        expect { candidate(predicate: bad) }.to raise_error(ArgumentError, /predicate can't use a subquery/), bad
      end
    end

    it "refuses aggregate, window, and grouping calls" do
      ["count(*) > 0", "sum(b) > 0", "pg_catalog.max(b) > 0", "MIN(b) > 0", "a > 0 AND avg(b) > 1",
       "count(DISTINCT b) > 1", "my_agg(b ORDER BY b) > 0", "my_agg(b) FILTER (WHERE b > 0) > 0",
       "my_agg(0.5) WITHIN GROUP (ORDER BY b) > 0", "rank() OVER () > 1", "my_window(b) OVER () > 1",
       "GROUPING(b) > 0", "my_agg(*) > 0", "my_agg(DISTINCT b) > 0", "JSON_ARRAYAGG(b) IS NOT NULL",
       "JSON_OBJECTAGG(b : c) IS NOT NULL"].each do |bad|
        expect { candidate(predicate: bad) }
          .to raise_error(ArgumentError, /predicate can't use an aggregate, window, or grouping function/), bad
      end
    end

    # The names in a fixture of real Postgres 18 output.
    def fixture_names(file)
      File.readlines(File.join(__dir__, "fixtures", file), chomp: true).grep_v(/\A#/).join(" ").split
    end

    it "refuses a plain call to every aggregate and window function built into Postgres 18" do
      names = fixture_names("pg18_aggregates.txt") | fixture_names("pg18_window_functions.txt")
      expect(names.size).to eq(61)

      names.each do |name|
        expect { candidate(predicate: "#{name}(b) > 0") }.to raise_error(ArgumentError, /aggregate/), name
      end
    end

    it "allows ordinary calls, including a schema's own function with an aggregate's name" do
      ["lower(note) = 'x'", "myschema.sum(b) > 0", "coalesce(b, 0) > 0", "b > 0 AND c IS NULL"].each do |ok|
        expect(candidate(predicate: ok).predicate).to be_a(String), ok
      end
    end

    it "allows a column named like a built-in aggregate or window function, since it's not a call" do
      ["lag > 0", "lead > 0", "count > 0 AND rank < 5"].each do |ok|
        expect(candidate(predicate: ok).predicate).to be_a(String), ok
      end
    end

    it "doesn't judge volatility, which needs the catalog" do
      expect(candidate(predicate: "b > random()").predicate).to eq("b > random()")
    end

    it "keeps casts, which don't normalize away" do
      expect(candidate(predicate: "status::text = 'open'")).not_to eq(candidate(predicate: "status = 'open'"))
    end
  end

  describe "what each built-in method supports" do
    it "refuses INCLUDE on brin, gin, and hash" do
      %i[brin gin hash].each do |method|
        expect { candidate(access_method: method, include: ["total"]) }
          .to raise_error(ArgumentError, /#{method} doesn't support INCLUDE/)
      end
    end

    it "allows INCLUDE on btree, gist, spgist, and methods it doesn't know" do
      %i[btree gist spgist my_custom_am].each do |method|
        expect(candidate(access_method: method, include: ["total"]).include).to eq(["total"]), method.to_s
      end
    end

    it "refuses more than one key column on hash and spgist" do
      %i[hash spgist].each do |method|
        expect { candidate(access_method: method, key: %w[a b]) }
          .to raise_error(ArgumentError, /#{method} doesn't support more than one key column/)
      end
    end

    it "allows several key columns on btree, gist, gin, brin, and methods it doesn't know" do
      %i[btree gist gin brin my_custom_am].each do |method|
        expect(candidate(access_method: method, key: %w[a b]).key.map(&:name)).to eq(%w[a b]), method.to_s
      end
    end

    it "makes from_ddl return nil for what the method doesn't support" do
      ["CREATE INDEX i ON public.orders USING brin (a) INCLUDE (b)",
       "CREATE INDEX i ON public.orders USING hash (a, b)"].each do |ddl|
        expect(described_class.from_ddl(ddl, sources: [:existing])).to be_nil, ddl
      end
    end
  end

  describe "ordering on methods other than btree" do
    it "refuses a non-default direction or nulls ordering" do
      expect do
        candidate(access_method: :brin, key: [key_column.new(name: "a", direction: :desc)])
      end.to raise_error(ArgumentError, /btree/)
      expect do
        candidate(access_method: :hash, key: [key_column.new(name: "a", nulls: :first)])
      end.to raise_error(ArgumentError, /btree/)
    end

    it "refuses it on any key column, not just the first" do
      expect do
        candidate(access_method: :gist, key: ["a", key_column.new(name: "b", direction: :desc)])
      end.to raise_error(ArgumentError, /only btree takes a non-default direction/)
    end

    it "allows the default ordering, even when it's spelled out" do
      c = candidate(access_method: :gist, key: [key_column.new(name: "a", direction: :asc, nulls: :last)])

      expect(c.to_ddl).to eq("CREATE INDEX ON public.orders USING gist (a)")
    end
  end

  it "keeps its helpers off the public API" do
    %i[parse_predicate bare_select column_name predicate access_method key_columns include_columns].each do |name|
      expect(described_class).not_to respond_to(name)
    end
    %i[key_columns include_columns column_name normalize_access_method check_ordering normalize_predicate
       index_params index_param relation definition].each do |name|
      expect(candidate).not_to respond_to(name)
    end
    expect(key_column.new(name: "a")).not_to respond_to(:pick)
    expect { Quaack::Enclave::IndexSql }.to raise_error(NameError, /private constant/)
    expect { Quaack::Enclave::IndexMethods }.to raise_error(NameError, /private constant/)
  end

  # The predicate can hold a real literal, which is value-class data. It may
  # appear in to_ddl, which only ever runs inside the enclave, but never in an
  # error message, inspect, to_s, or pp, which can end up in logs.
  describe "keeping predicate literals out of messages" do
    let(:sentinel) { "SENTINEL-7f3a9c" }

    # The whole report Ruby would print or log for the error, which
    # includes any exception it was raised from.
    def message_of
      yield
      raise "expected an error"
    rescue ArgumentError => e
      e.full_message(highlight: false)
    end

    it "plants the sentinel where the checks below look for it" do
      c = candidate(predicate: "note = '#{sentinel}'")

      expect(c.predicate).to include(sentinel)
      expect(c.to_ddl).to include(sentinel)
    end

    it "redacts the predicate in inspect, to_s, and pp" do
      c = candidate(predicate: "note = '#{sentinel}'")

      [c.inspect, c.to_s, PP.pp(c, +"")].each do |shown|
        expect(shown).not_to include(sentinel)
        expect(shown).to include("predicate=<redacted>", "customer_id", "parse")
      end
      expect(candidate.inspect).to include("predicate=nil")
    end

    it "leaves it out of the errors for a predicate that isn't one expression or doesn't parse" do
      ["note = '#{sentinel}' UNION SELECT 1", "note = 1 '#{sentinel}'", "note = '#{sentinel}' AND AND"].each do |bad|
        expect(message_of { candidate(predicate: bad) }).not_to include(sentinel)
      end
    end

    # Everything a failed pattern match can show: the message, the full
    # report, and, for a missing key, the hash it was matching and the key.
    def pattern_error_text
      yield
      raise "expected the pattern not to match"
    rescue NoMatchingPatternKeyError => e
      [e.message, e.full_message(highlight: false), e.matchee.inspect, e.key.inspect].join("\n")
    rescue NoMatchingPatternError => e
      [e.message, e.full_message(highlight: false)].join("\n")
    end

    it "leaves it out of failed pattern matches" do
      c = candidate(predicate: "note = '#{sentinel}'")
      texts = [
        pattern_error_text { c => { predicate: "other" } },
        pattern_error_text { c => { predicate: String, nope: 1 } },
        pattern_error_text { c => { nope: 1 } },
        pattern_error_text { c => [*, "other", *] },
        pattern_error_text do
          case c
          in { predicate: "other" } then nil
          end
        end
      ]

      texts.each { |text| expect(text).not_to include(sentinel) }
      expect(texts[3]).to include("deconstruct")
    end

    it "doesn't expose the predicate to pattern matching, but still matches the other members" do
      c = candidate(predicate: "note = '#{sentinel}'", unique: true)

      expect(c.deconstruct_keys(nil)).not_to have_key(:predicate)
      expect(c.deconstruct_keys(%i[predicate unique])).to eq({ unique: true })
      expect(c).not_to respond_to(:deconstruct)
      hides_predicate = (c in { predicate: String })
      matches_the_rest = (c in { unique: true, key: [{ name: "customer_id" }], access_method: :btree })

      expect([hides_predicate, matches_the_rest]).to eq([false, true])
    end

    it "leaves it out of the errors for a parameter, subquery, or aggregate" do
      ["note = '#{sentinel}' AND a = $1", "note IN (SELECT '#{sentinel}')", "count(*) > 0 AND note = '#{sentinel}'"]
        .each do |bad|
        message = message_of { candidate(predicate: bad) }
        expect(message).to include("predicate can't use")
        expect(message).not_to include(sentinel)
      end
    end

    it "leaves it out of the error for merging a different definition" do
      a = candidate(predicate: "note = '#{sentinel}'")
      b = candidate(key: ["other"], predicate: "note = '#{sentinel}-2'")

      expect(message_of { a.merge_sources(b) }).not_to include(sentinel)
    end

    it "leaves it out of from_ddl's errors" do
      ["CREATE INDEX ON public.orders (a) WHERE note = '#{sentinel}'; SELECT 1",
       "CREATE INDEX ON public.orders (a) WHERE note = 1 '#{sentinel}'"].each do |bad|
        expect(message_of { described_class.from_ddl(bad, sources: [:existing]) }).not_to include(sentinel)
      end
    end
  end

  describe ".from_ddl" do
    def from_ddl(sql) = described_class.from_ddl(sql, sources: [:existing])

    # Read back, this would be a candidate for different rows. Postgres 18
    # prints IS NOT DISTINCT FROM as NOT (... IS DISTINCT FROM ...), which
    # pg_query deparses faithfully, so this is written by hand.
    it "gives nil for a predicate pg_query deparses as a different expression" do
      ddl = "CREATE INDEX odd_idx ON public.orders USING btree (id) " \
            "WHERE ((status = 'x'::text) IS NOT DISTINCT FROM ((total_cents > 1) AND (customer_id > 2)))"
      expect(from_ddl(ddl.sub("IS NOT DISTINCT", "IS DISTINCT"))).to be_a(described_class)

      expect(from_ddl(ddl)).to be_nil
    end

    it "reads an index definition as pg_get_indexdef prints it" do
      c = from_ddl("CREATE INDEX orders_status_idx ON public.orders USING btree " \
                   "(status, \"Created At\" DESC NULLS LAST, id NULLS FIRST) INCLUDE (total) " \
                   "WHERE ((status)::text = 'open'::text)")

      expect(c).to eq(
        described_class.new(
          table: orders,
          key: ["status", key_column.new(name: "Created At", direction: :desc, nulls: :last),
                key_column.new(name: "id", nulls: :first)],
          include: ["total"], predicate: "status::text = 'open'::text", sources: [:parse]
        )
      )
      expect(c.sources).to eq(Set[:existing])
    end

    it "reads other methods, explicit ASC, and a default nulls ordering spelled out" do
      expect(from_ddl("CREATE INDEX i ON public.orders USING brin (created_at)"))
        .to eq(candidate(key: ["created_at"], access_method: :brin))
      expect(from_ddl("CREATE INDEX i ON public.orders USING btree (a ASC NULLS LAST, b DESC NULLS FIRST)"))
        .to eq(candidate(key: ["a", key_column.new(name: "b", direction: :desc)]))
    end

    it "round-trips what to_ddl renders" do
      [
        candidate,
        candidate(key: ["a", key_column.new(name: "b", direction: :desc, nulls: :last)], include: %w[c d],
                  predicate: "c > 0 AND d IS NOT NULL"),
        described_class.new(table: Quaack::Enclave::TableName.new(schema: "My Schema", name: "order"),
                            key: %w[CustomerId select], include: ["line item"], access_method: :gist,
                            sources: [:parse])
      ].each do |c|
        expect(from_ddl(c.to_ddl)).to eq(c), c.to_ddl
      end
    end

    describe "unique indexes, as Postgres 18 prints them" do
      # Index name => pg_get_indexdef output, from a real Postgres 18.
      let(:indexdefs) do
        File.readlines(File.join(__dir__, "fixtures", "pg18_unique_indexdefs.txt"), chomp: true)
            .grep_v(/\A#/).to_h { |line| [line[/INDEX (\S+) ON/, 1], line] }
      end

      def unique(**overrides) = candidate(unique: true, **overrides)

      it "reads a primary key, a UNIQUE column, and a two-column UNIQUE constraint" do
        expect(from_ddl(indexdefs.fetch("orders_pkey"))).to eq(unique(key: ["id"]))
        expect(from_ddl(indexdefs.fetch("orders_email_key"))).to eq(unique(key: ["email"]))
        expect(from_ddl(indexdefs.fetch("orders_a_b_key"))).to eq(unique(key: %w[a b]))
      end

      it "reads CREATE UNIQUE INDEX with INCLUDE, a predicate, and a direction" do
        expect(from_ddl(indexdefs.fetch("orders_c_idx")))
          .to eq(unique(key: ["c"], include: ["d"], predicate: "e > 0"))
        expect(from_ddl(indexdefs.fetch("orders_e_desc_idx")))
          .to eq(unique(key: [key_column.new(name: "e", direction: :desc, nulls: :last)]))
      end

      it "returns nil for NULLS NOT DISTINCT, which the shape doesn't model" do
        expect(from_ddl(indexdefs.fetch("orders_d_nnd_idx"))).to be_nil
      end

      it "reads a deferrable UNIQUE constraint as unique, since pg_get_indexdef prints it the same way" do
        d = Quaack::Enclave::TableName.new(schema: "public", name: "d")

        expect(from_ddl(indexdefs.fetch("d_a_key"))).to eq(unique(table: d, key: ["a"]))
      end

      it "turns an existing unique index into a plain candidate that matches a generator's" do
        pkey = from_ddl(indexdefs.fetch("orders_pkey"))
        extended = pkey.with(key: [*pkey.key, key_column.new(name: "status")], unique: false, sources: [:plan])

        expect(extended).to eq(candidate(key: %w[id status]))
        expect(extended.sources).to eq(Set[:plan])
        expect(pkey.with(key: [*pkey.key, key_column.new(name: "status")])).not_to eq(candidate(key: %w[id status]))
      end

      it "reads a plain index as not unique" do
        expect(from_ddl("CREATE INDEX i ON public.orders USING btree (id)").unique).to be(false)
      end
    end

    it "returns nil for an index it can't represent" do
      [
        "CREATE INDEX i ON ONLY public.orders USING btree (a)",
        "CREATE INDEX i ON public.orders USING btree (a) WITH (fillfactor='70')",
        "CREATE INDEX i ON public.orders USING btree (a) TABLESPACE fast",
        "CREATE INDEX i ON orders USING btree (a)",
        "CREATE INDEX i ON public.orders USING gist (a DESC)",
        "CREATE INDEX i ON public.orders USING btree (a) INCLUDE (a)",
        # pg_get_indexdef never prints these, so from_ddl doesn't take them.
        "CREATE INDEX CONCURRENTLY i ON public.orders USING btree (a)",
        "CREATE INDEX IF NOT EXISTS i ON public.orders USING btree (a)"
      ].each do |ddl|
        expect(from_ddl(ddl)).to be_nil, ddl
      end
    end

    it "raises for anything that isn't one CREATE INDEX" do
      ["SELECT 1", "CREATE INDEX ON public.t (a); CREATE INDEX ON public.t (b)", "CREATE INDEX ON"].each do |bad|
        expect { from_ddl(bad) }.to raise_error(ArgumentError, /CREATE INDEX/), bad
      end
    end
  end
end
