# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_schema"
require "quaack/enclave/predicate_atoms"
require "quaack/enclave/value_pools"

# rewrite-test: each atom's pool of interesting values, sorted by Postgres itself
# into the values that satisfy the atom and the ones that fail it.
RSpec.describe Quaack::Enclave::ValuePools do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:orders) { Quaack::Enclave::TableName.new(schema: "fx", name: "orders") }
  let(:customers) { Quaack::Enclave::TableName.new(schema: "fx", name: "customers") }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx; CREATE TABLE fx.customers (id integer PRIMARY KEY, name text NOT NULL);
      CREATE TABLE fx.orders (id integer PRIMARY KEY, customer_id integer REFERENCES fx.customers,
                           qty integer, status text NOT NULL, placed date NOT NULL, note text);
    SQL
  end

  def pools(where, from: "fx.orders o")
    parse = PgQuery.parse("SELECT 1 FROM #{from} WHERE #{where}")
    schema = Quaack::Enclave::ArenaSchema.load(conn, [orders, customers])
    atoms = Quaack::Enclave::PredicateAtoms.extract(parse, column_names: schema.column_names)
    described_class.build(conn, parse, atoms, schema)
  end

  def pool(where) = pools(where).fetch(0)

  it "gives an array type none of its element type's boundaries" do
    expect(described_class.boundaries("bigint[]")).to eq([])
    expect(described_class.boundaries("character varying(20)[]")).to eq([])
    expect(described_class.boundaries("timestamp with time zone[]")).to eq([])
    expect(described_class.boundaries("bigint")).to include("9223372036854775807")
    expect(described_class.boundaries("character varying(20)")).to eq(["", "~"])
  end

  it "sorts the literal, a unit either side, and the type's boundaries for an integer equality" do
    p = pool("o.qty = 5")
    expect(p.satisfying).to eq(["5"])
    expect(p.failing).to include("4", "6", "-2147483648", "2147483647")
    expect(p.column).to eq(Quaack::Enclave::PredicateAtoms::Column.new(table: orders, refname: "o", name: "qty"))
    expect(p.nullable).to be(true)
  end

  it "puts the literal and the day after it on the satisfying side of a date range" do
    p = pool("o.placed >= '2024-03-01'")
    expect(p.satisfying.first(2)).to eq(%w[2024-03-01 2024-03-02])
    expect(p.failing).to include("2024-02-29", "-infinity")
    expect(p.satisfying).to include("infinity")
    expect(p.nullable).to be(false)
  end

  it "adds case variants for text" do
    p = pool("o.status = 'open'")
    expect(p.satisfying).to eq(["open"])
    expect(p.failing).to include("OPEN", "")
    expect(p.inspect).not_to include("open")
  end

  it "asks Postgres, so an expression on the column sorts case variants right" do
    p = pools("lower(c.name) = 'bob'", from: "fx.customers c").fetch(0)
    expect(p.satisfying).to include("bob", "BOB")
  end

  it "adds a matching and a non-matching value for LIKE" do
    p = pool("o.status LIKE 'op_n%'")
    expect(p.satisfying).to include("opxn")
    expect(p.failing).to include("\u0001opxn\u0001", "OPXN")
  end

  it "takes every element of an IN list" do
    p = pool("o.qty IN (1, 3)")
    expect(p.satisfying).to eq(%w[1 3])
    expect(p.failing).to include("0", "2", "4")
  end

  it "satisfies IS NULL only with NULL" do
    p = pool("o.note IS NULL")
    expect(p.satisfying).to eq([nil])
    expect(p.failing).to include("")
  end

  it "gives no pool to a join or a two-column atom" do
    all = pools("o.customer_id = c.id AND o.qty = o.id AND o.qty = 2",
                from: "fx.orders o JOIN fx.customers c ON true")
    expect(all.keys).to eq([2])
  end
end
