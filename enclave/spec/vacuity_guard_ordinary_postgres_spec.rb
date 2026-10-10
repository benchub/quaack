# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/vacuity_guard"

# vacuity-guard on the ordinary queries ORMs generate (20261010-25). Each
# atom here can change a result fixture-compare checks, so none may come
# back untested.
RSpec.describe Quaack::Enclave::VacuityGuard do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TYPE fx.mood AS ENUM ('happy', 'sad');
      CREATE TABLE fx.users (id bigint PRIMARY KEY, email text NOT NULL UNIQUE, state text NOT NULL,
        admin boolean NOT NULL DEFAULT false, mood fx.mood, created_at timestamp NOT NULL);
      CREATE TABLE fx.posts (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
        score integer NOT NULL DEFAULT 0, parent_id bigint REFERENCES fx.posts);
    SQL
  end

  def untested(sql)
    builder = Quaack::Enclave::Scenarios::Builder.new(conn, PgQuery.parse(sql))
    described_class.run(runner, builder, sql).untested
  end

  # Unordered, LIMIT 1 may return the hit whichever atom is loosened.
  # fixture-compare's subset check, in its reverse load, sees the near miss.
  it "tests a filter under an unordered LIMIT 1" do
    expect(untested("SELECT * FROM fx.users WHERE fx.users.email = 'x' LIMIT 1")).to eq([])
  end

  # Every created_at ties, so the LIMIT cuts a tie group.
  it "tests a filter under ORDER BY ... LIMIT 1" do
    sql = "SELECT * FROM fx.users WHERE fx.users.state = 'a' ORDER BY fx.users.created_at DESC LIMIT 1"
    expect(untested(sql)).to eq([])
  end

  # The near miss for state needs the hit's email, which is unique, so it
  # goes in a further S1 fixture, which fixture-compare also runs.
  it "tests a filter whose near miss shares a unique value with the hit" do
    sql = "SELECT fx.users.id FROM fx.users WHERE fx.users.email = 'a@b' AND fx.users.state = 'a'"
    expect(untested(sql)).to eq([])
  end

  it "tests an enum filter on a nullable column" do
    expect(untested("SELECT * FROM fx.users WHERE fx.users.mood = 'happy'")).to eq([])
  end

  # The near miss's row must differ from the hit's in the column DISTINCT
  # keeps, or the two collapse into one.
  it "tests a filter on a column DISTINCT doesn't keep" do
    expect(untested("SELECT DISTINCT fx.users.state FROM fx.users WHERE fx.users.admin = true")).to eq([])
  end

  it "tests a join and a filter under GROUP BY" do
    sql = "SELECT fx.users.id, count(fx.posts.id) FROM fx.users JOIN fx.posts " \
          "ON fx.posts.user_id = fx.users.id WHERE fx.users.state = 'a' GROUP BY fx.users.id"
    expect(untested(sql)).to eq([])
  end

  it "tests an IN list on the joined parent's key" do
    sql = "SELECT fx.posts.* FROM fx.posts JOIN fx.users ON fx.users.id = fx.posts.user_id " \
          "WHERE fx.users.id IN (4, 5)"
    expect(untested(sql)).to eq([])
  end

  # WITH TIES is a comparison fixture-compare refuses, and a refusal
  # compares nothing, so it can't make an atom tested that equal rows
  # leave vacuous: neither the redundant id > -5 nor id > 0, whose near
  # miss sorts after the hit's tie.
  it "leaves atoms untested when fixture-compare refuses the cut" do
    sql = "SELECT * FROM fx.users WHERE fx.users.id > 0 AND fx.users.id > -5 " \
          "ORDER BY fx.users.created_at FETCH FIRST 1 ROWS WITH TIES"
    expect(untested(sql)).to eq(["fx.users.id > $1", "fx.users.id > $2"])
  end

  # Five rows can't reach OFFSET 40, so loosening the filter changes no
  # result fixture-compare sees. That stays untested, honestly.
  it "leaves a filter untested behind an OFFSET past the fixture" do
    sql = "SELECT * FROM fx.posts WHERE fx.posts.score > 5 ORDER BY fx.posts.id LIMIT 20 OFFSET 40"
    expect(untested(sql)).to eq(["fx.posts.score > $1"])
  end

  # 20261010-26: the comparisons fixture-compare runs for the guard, each
  # as [fixture rows, loosened query, inserts].
  def comparisons
    calls = []
    allow(Quaack::Enclave::ResultComparison).to receive(:compare_in_load_orders)
      .and_wrap_original do |original, runner, rows, **kw|
        calls << [rows, kw[:candidate], kw[:inserts]]
        original.call(runner, rows, **kw)
      end
    calls
  end

  # The original returns nothing on the fixture, so neither query can
  # return a row any load order puts in a different place.
  it "runs no comparison when the OFFSET is past the original's rows" do
    calls = comparisons
    sql = "SELECT * FROM fx.posts WHERE fx.posts.score > 5 ORDER BY fx.posts.id LIMIT 20 OFFSET 40"
    expect(untested(sql)).to eq(["fx.posts.score > $1"])
    expect(calls).to eq([])
  end

  # A retry that rebuilds the same fixture can't change a comparison
  # that showed no mismatch, so none runs twice.
  it "compares an atom on the same fixture once across retries" do
    calls = comparisons
    sql = "SELECT * FROM fx.users WHERE fx.users.id > 0 AND fx.users.id > -5 " \
          "ORDER BY fx.users.created_at FETCH FIRST 1 ROWS WITH TIES"
    expect(untested(sql)).to eq(["fx.users.id > $1", "fx.users.id > $2"])
    expect(calls).not_to be_empty
    expect(calls.size).to eq(calls.uniq.size)
  end

  # email needs a comparison to count as tested: its near miss ties the
  # hit on state, so only a load order shows it (an unordered LIMIT 1 gets
  # the near misses alone instead, 20261010-31); state changes the rows.
  # Past the cap, email stays untested.
  describe "the cap on comparisons per query" do
    let(:sql) do
      "SELECT * FROM fx.users WHERE fx.users.email = 'x' AND fx.users.state = 'a' ORDER BY fx.users.state LIMIT 1"
    end

    it "tests both atoms under the cap" do
      calls = comparisons
      expect(untested(sql)).to eq([])
      expect(calls.size).to be_between(1, described_class::MAX_COMPARISONS)
    end

    it "leaves the atoms past the cap untested" do
      stub_const("#{described_class}::MAX_COMPARISONS", 0)
      calls = comparisons
      expect(untested(sql)).to eq(["fx.users.email = $1"])
      expect(calls.size).to eq(0)
    end

    it "counts every fixture and retry of the query against the cap" do
      stub_const("#{described_class}::MAX_COMPARISONS", 3)
      calls = comparisons
      untested("SELECT * FROM fx.users WHERE fx.users.id > 0 AND fx.users.id > -5 " \
               "ORDER BY fx.users.created_at FETCH FIRST 1 ROWS WITH TIES")
      expect(calls.size).to eq(3)
    end
  end
end
