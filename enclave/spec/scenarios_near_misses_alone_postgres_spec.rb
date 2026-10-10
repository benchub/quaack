# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/scenarios"

# Near misses alone (20261010-31): for a top-level LIMIT with no ORDER BY,
# S1 gets a further fixture holding its near misses and no hit, since with
# the hit present the result is one row however many rows match.
RSpec.describe Quaack::Enclave::Scenarios::Builder do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.users (id bigint PRIMARY KEY, email text NOT NULL, name text NOT NULL);
    SQL
  end

  def build(sql)
    builder = described_class.new(conn, PgQuery.parse(sql))
    [builder.build, builder.spills]
  end

  def names(rows) = rows.map { |r| r.columns.zip(r.values).to_h.fetch("name") }

  it "adds a fixture of S1's near misses alone, with no hit, for LIMIT without ORDER BY" do
    scenarios, spills = build("SELECT 1 AS one FROM fx.users WHERE fx.users.email = 'a@b' " \
                              "AND fx.users.name = 'ann' LIMIT 1")
    s1 = scenarios[:s1].map { |r| r.columns.zip(r.values).to_h }
    near = s1.reject { it["email"] == "a@b" && it["name"] == "ann" }
    expect(spills.fetch(:s1).size).to eq(1)
    alone = spills.fetch(:s1).first.map { |r| r.columns.zip(r.values).to_h }
    expect(alone).to eq(near)
    expect(near.size).to eq(2)
  end

  it "adds none with an ORDER BY, or with no LIMIT, so those scenarios don't change" do
    [
      "SELECT 1 AS one FROM fx.users WHERE fx.users.email = 'a@b' ORDER BY fx.users.id LIMIT 1",
      "SELECT 1 AS one FROM fx.users WHERE fx.users.email = 'a@b'"
    ].each { |sql| expect(build(sql).last).to eq({}), sql }
  end

  it "doesn't count the near misses alone as dropped" do
    builder = described_class.new(conn, PgQuery.parse("SELECT 1 FROM fx.users WHERE fx.users.email = 'a@b' LIMIT 1"))
    builder.build
    expect(builder.dropped).to eq(0)
    expect(names(builder.spills.fetch(:s1).first).size).to eq(1)
  end
end
