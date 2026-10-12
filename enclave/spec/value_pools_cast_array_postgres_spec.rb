# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_schema"
require "quaack/enclave/predicate_atoms"
require "quaack/enclave/scenario_tests"
require "quaack/enclave/value_pools"

# Postgres prints IN on a character varying column as = ANY over an ARRAY
# cast to text[]: ((state)::text = ANY ((ARRAY['a'::character varying,
# ...])::text[])). Each element is a value, not the whole array
# (20261012-1).
RSpec.describe Quaack::Enclave::ValuePools do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:subs) { Quaack::Enclave::TableName.new(schema: "fx", name: "subs") }
  let(:schema) { Quaack::Enclave::ArenaSchema.load_closure(conn, [subs]) }
  let(:labels) { %w[none missing late extended] }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.subs (id integer PRIMARY KEY, kind varchar(20), tags text[],
                            late_policy_status character varying NOT NULL
                              CHECK (late_policy_status IN ('none', 'missing', 'late', 'extended')));
    SQL
  end

  def pool(where)
    parse = PgQuery.parse("SELECT 1 FROM fx.subs s WHERE #{where}")
    atoms = Quaack::Enclave::PredicateAtoms.extract(parse, column_names: schema.column_names)
    described_class.build(conn, parse, atoms, schema).fetch(0)
  end

  describe "a CHECK's IN list on a varchar column" do
    let(:checks) { Quaack::Enclave::Scenarios::Checks.new(conn, schema) }
    let(:col) { schema.column(subs, "late_policy_status") }

    it "prints as an ARRAY cast to text[]" do
      definition = conn.exec(<<~SQL).getvalue(0, 0)
        SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid = 'fx.subs'::regclass AND contype = 'c'
      SQL
      expect(definition).to include("(ARRAY['none'::character varying, ").and include("])::text[]")
    end

    it "gives each listed value as one of the CHECK's own values" do
      expect(checks.values(subs, col)).to eq(labels)
    end

    it "finds a satisfying value when no preferred value passes" do
      expect(checks.satisfying(subs, col, ["nope"])).to eq("none")
    end
  end

  it "pools each element of a query's = ANY over an ARRAY cast to text[]" do
    p = pool("s.kind = ANY (ARRAY['open', 'shut']::text[])")
    expect(p.satisfying).to eq(%w[open shut])
    expect(p.failing).to include("OPEN", "")
  end

  it "pools each element when the column is cast to text too" do
    p = pool("s.kind::text = ANY ((ARRAY['open'::varchar, 'shut'::varchar])::text[])")
    expect(p.satisfying).to eq(%w[open shut])
  end

  it "pools each element of a query's <> ALL over an ARRAY cast to text[] (how NOT IN prints)" do
    p = pool("s.kind::text <> ALL ((ARRAY['open'::varchar, 'shut'::varchar])::text[])")
    expect(p.failing.first(2)).to eq(%w[open shut])
  end

  it "keeps a cast ARRAY whole when it's compared with an array column" do
    p = pool("s.tags = ARRAY['open', 'shut']::text[]")
    expect(p.satisfying).to eq(["{open,shut}"])
  end

  it "pools each element under nested casts" do
    p = pool("s.kind = ANY (ARRAY['open', 'shut']::varchar[]::text[])")
    expect(p.satisfying).to eq(%w[open shut])
  end
end
