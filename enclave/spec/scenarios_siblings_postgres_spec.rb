# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/scenarios"

# Siblings (20261010-24): a near miss on a child table whose column another
# scope tests too gets a second child row under the same parent, one that
# passes the atom.
RSpec.describe Quaack::Enclave::Scenarios do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.users (id bigint PRIMARY KEY, state text NOT NULL);
      CREATE TABLE fx.posts (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
        score integer NOT NULL);
    SQL
  end

  def posts(sql)
    described_class.build(conn, PgQuery.parse(sql))[:s1].select { it.table.name == "posts" }
                                                        .map { it.columns.zip(it.values).to_h }
  end

  def passing_siblings(rows)
    missed = rows.reject { it["score"].to_i > 5 }.map { it["user_id"] }
    rows.select { it["score"].to_i > 5 && missed.include?(it["user_id"]) }
  end

  it "gives a near miss whose column another scope tests a passing sibling under its parent" do
    sql = "SELECT fx.users.id FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
          "AND fx.posts.score > 5 WHERE fx.users.id IN (SELECT fx.posts.user_id FROM fx.posts " \
          "WHERE fx.posts.score > 5)"
    expect(passing_siblings(posts(sql))).not_to be_empty
  end

  # A root table's row has no parent to share, so a sibling there would be
  # just another row (20261010-34).
  it "adds no sibling for an atom on a root table that two scopes test" do
    sql = "SELECT fx.users.id FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
          "AND fx.users.state = 'a' WHERE fx.users.id IN (SELECT fx.users.id FROM fx.users " \
          "WHERE fx.users.state = 'a')"
    s1 = described_class.build(conn, PgQuery.parse(sql))[:s1]
    users = s1.select { it.table.name == "users" }.map { it.columns.zip(it.values).to_h }
    expect(users.size).to eq(3)
    expect(users.count { it["state"] == "a" }).to eq(1)
  end

  it "adds no sibling when only one scope tests the column" do
    sql = "SELECT fx.users.id FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
          "WHERE fx.posts.score > 5 AND fx.users.state = 'a'"
    expect(passing_siblings(posts(sql))).to eq([])
  end
end
