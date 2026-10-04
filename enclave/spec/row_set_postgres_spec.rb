# frozen_string_literal: true

require "delegate"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"

# RowSet leaves out a group whose row collides with an earlier one on a
# unique key, read from arena's catalog, including expression, INCLUDE,
# partial, and NULLS NOT DISTINCT unique indexes.
RSpec.describe Quaack::Enclave::Scenarios::RowSet do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:table) { Quaack::Enclave::TableName.new(schema: "fx", name: "t") }

  before { conn.exec("CREATE SCHEMA fx") }

  def row_set(ddl)
    conn.exec(ddl)
    described_class.new(Quaack::Enclave::ArenaSchema.load_closure(conn, [table]), conn)
  end

  def row(**pairs)
    Quaack::Enclave::ArenaRunner::FixtureRow.new(table:, columns: pairs.keys.map(&:to_s), values: pairs.values)
  end

  def adds(set, *rows) = rows.map { |r| set.add?([r]) }

  it "catches rows whose expression key collides though the column values differ" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, email text NOT NULL);
                   CREATE UNIQUE INDEX ON fx.t (lower(email))")
    expect(adds(set, row(id: "1", email: "A"), row(id: "2", email: "b"), row(id: "3", email: "a")))
      .to eq([true, true, false])
  end

  it "evaluates a multi-key expression index with a plain column key" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, email text, org integer);
                   CREATE UNIQUE INDEX ON fx.t (org, lower(email))")
    expect(adds(set, row(id: "1", email: "A", org: "1"), row(id: "2", email: "a", org: "2"),
                row(id: "3", email: "a", org: "1"), row(id: "4", email: nil, org: "1"),
                row(id: "5", email: nil, org: "1")))
      .to eq([true, true, false, true, true])
  end

  it "makes NULL keys collide under NULLS NOT DISTINCT" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, k integer UNIQUE NULLS NOT DISTINCT)")
    expect(adds(set, row(id: "1", k: nil), row(id: "2", k: nil))).to eq([true, false])
  end

  it "makes NULL expression keys collide under NULLS NOT DISTINCT" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, email text);
                   CREATE UNIQUE INDEX ON fx.t (lower(email)) NULLS NOT DISTINCT")
    expect(adds(set, row(id: "1", email: nil), row(id: "2", email: nil))).to eq([true, false])
  end

  it "lets NULL keys through without NULLS NOT DISTINCT" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, k integer UNIQUE)")
    expect(adds(set, row(id: "1", k: nil), row(id: "2", k: nil))).to eq([true, true])
  end

  it "keys a unique index on its key columns, not its INCLUDE columns" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, a integer, b integer);
                   CREATE UNIQUE INDEX ON fx.t (a) INCLUDE (b)")
    expect(adds(set, row(id: "1", a: "1", b: "7"), row(id: "2", a: "2", b: "7"), row(id: "3", a: "1", b: "8")))
      .to eq([true, true, false])
  end

  it "treats a partial unique index as always unique" do
    set = row_set("CREATE TABLE fx.t (id integer PRIMARY KEY, a integer, live boolean);
                   CREATE UNIQUE INDEX ON fx.t (a) WHERE live")
    expect(adds(set, row(id: "1", a: "1", live: "f"), row(id: "2", a: "1", live: "f"))).to eq([true, false])
  end

  # The catalog never prints a key like this, but if one ever reads as
  # more than one expression it must not be spliced into SQL and run.
  it "drops a group whose expression key isn't one expression, without running it" do
    conn.exec("CREATE TABLE fx.t (id integer PRIMARY KEY, email text NOT NULL);
               CREATE UNIQUE INDEX ON fx.t (lower(email))")
    real = Quaack::Enclave::ArenaSchema.load_closure(conn, [table])
    crafted = real.constraints(table).then do |c|
      c.with(expressions: c.expressions.map { |e| e.with(keys: ["lower(email)), (upper(email)"]) })
    end
    schema = SimpleDelegator.new(real)
    schema.define_singleton_method(:constraints) { |_t| crafted }
    sent = []
    real_conn = conn
    spy = SimpleDelegator.new(conn)
    spy.define_singleton_method(:exec_params) { |sql, *args| (sent << sql) && real_conn.exec_params(sql, *args) }
    set = described_class.new(schema, spy)
    expect(adds(set, row(id: "1", email: "A"), row(id: "2", email: "b"))).to eq([false, false])
    expect(sent.grep(/upper/)).to eq([])
  end

  # Task 20261003-40: a group whose row points at a parent row that isn't
  # there, because its group was left out, is left out too.
  context "with foreign keys" do
    let(:table) { Quaack::Enclave::TableName.new(schema: "fx", name: "c") }

    def row_in(name, **pairs)
      Quaack::Enclave::ArenaRunner::FixtureRow.new(table: Quaack::Enclave::TableName.new(schema: "fx", name:),
                                                   columns: pairs.keys.map(&:to_s), values: pairs.values)
    end

    it "leaves out every row down a chain from a parent left out" do
      set = row_set("CREATE TABLE fx.a (id integer PRIMARY KEY, name text UNIQUE);
                     CREATE TABLE fx.b (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a);
                     CREATE TABLE fx.c (id integer PRIMARY KEY, b_id integer NOT NULL REFERENCES fx.b)")
      expect([set.add?([row_in("a", id: "1", name: "x")]), set.add?([row_in("a", id: "2", name: "x")]),
              set.add?([row_in("b", id: "1", a_id: "2")]), set.add?([row_in("c", id: "1", b_id: "1")]),
              set.add?([row_in("b", id: "2", a_id: "1")]), set.add?([row_in("c", id: "2", b_id: "2")])])
        .to eq([true, false, false, false, true, true])
    end

    it "takes a parent from the group itself, even one listed after the row that points at it" do
      set = row_set("CREATE TABLE fx.a (id integer PRIMARY KEY);
                     CREATE TABLE fx.c (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a)")
      expect(set.add?([row_in("c", id: "1", a_id: "1"), row_in("a", id: "1")])).to be(true)
    end

    # MATCH SIMPLE: a key with any NULL column points at nothing.
    it "doesn't check a composite foreign key with a NULL column" do
      set = row_set("CREATE TABLE fx.a (t integer, id integer, PRIMARY KEY (t, id));
                     CREATE TABLE fx.c (id integer PRIMARY KEY, t integer, a_id integer,
                       FOREIGN KEY (t, a_id) REFERENCES fx.a (t, id))")
      expect([set.add?([row_in("c", id: "1", t: nil, a_id: "9")]), set.add?([row_in("c", id: "2", t: "1", a_id: "9")])])
        .to eq([true, false])
    end

    it "leaves out a group whose own rows collide, and keeps none of them" do
      set = row_set("CREATE TABLE fx.a (id integer PRIMARY KEY, name text UNIQUE);
                     CREATE TABLE fx.c (id integer PRIMARY KEY, a_id integer REFERENCES fx.a)")
      expect(set.add?([row_in("a", id: "1", name: "x"), row_in("a", id: "2", name: "x")])).to be(false)
      expect(set.in_order(%w[a c].map { Quaack::Enclave::TableName.new(schema: "fx", name: it) })).to eq([])
    end

    it "finds the rows a group points at, and theirs" do
      set = row_set("CREATE TABLE fx.a (id integer PRIMARY KEY);
                     CREATE TABLE fx.b (id integer PRIMARY KEY, a_id integer NOT NULL REFERENCES fx.a);
                     CREATE TABLE fx.c (id integer PRIMARY KEY, b_id integer NOT NULL REFERENCES fx.b)")
      a = row_in("a", id: "1")
      b = row_in("b", id: "1", a_id: "1")
      set.add?([a, b, row_in("b", id: "2", a_id: "1")])
      expect(set.parents_of([row_in("c", id: "1", b_id: "1")])).to eq([b, a])
    end
  end
end
