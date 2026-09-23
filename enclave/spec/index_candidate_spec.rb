# frozen_string_literal: true

require "pg_query"
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

    it "requires a non-empty key" do
      expect { candidate(key: []) }.to raise_error(ArgumentError, /key/)
    end

    it "rejects a column that's in both the key and INCLUDE" do
      expect { candidate(key: %w[a b], include: %w[c b]) }.to raise_error(ArgumentError, /"b"/)
    end

    it "requires a schema-qualified TableName" do
      expect { candidate(table: "orders") }.to raise_error(ArgumentError, /TableName/)
    end

    it "requires the predicate to be SQL text or nil" do
      expect { candidate(predicate: 1) }.to raise_error(ArgumentError, /predicate/)
      expect { candidate(predicate: "  ") }.to raise_error(ArgumentError, /predicate/)
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
        candidate(key: %w[a b], include: ["c"], access_method: :hash),
        candidate(key: %w[a b], include: ["c"], predicate: "c > 0"),
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

    it "refuses a predicate that isn't a single expression" do
      ["true; DROP TABLE orders", "a = 1 UNION SELECT 1", "a = 1 ORDER BY 1", "a = 1 LIMIT 1",
       "a = 1) OR (true", "a = = 1"].each do |bad|
        expect { candidate(predicate: bad).to_ddl }.to raise_error(ArgumentError, /predicate/), bad.inspect
      end
    end
  end
end
