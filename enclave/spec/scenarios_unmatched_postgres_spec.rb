# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/scenarios"

# Unmatched groups (20261010-30): a parent with no child, for a join atom an
# outer join or a correlated subquery leaves the child optional to.
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

  def rows(sql, table)
    s1 = described_class.build(conn, PgQuery.parse(sql))[:s1]
    s1.select { it.table.name == table }.map { it.columns.zip(it.values).to_h }
  end

  def childless_users(sql)
    parents = rows(sql, "posts").map { it["user_id"] }
    rows(sql, "users").reject { parents.include?(it["id"]) }.map { it["state"] }
  end

  it "builds a user with no post for a NOT EXISTS, and a near miss of its filter" do
    sql = "SELECT fx.users.id FROM fx.users WHERE fx.users.state = 'a' AND NOT EXISTS " \
          "(SELECT 1 FROM fx.posts WHERE fx.posts.user_id = fx.users.id)"
    expect(childless_users(sql)).to contain_exactly("a", satisfy { it != "a" })
  end

  it "builds a user with no post for a LEFT JOIN's right side" do
    sql = "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
          "WHERE fx.posts.id IS NULL"
    expect(childless_users(sql).size).to eq(1)
  end

  it "builds none for an inner join, a LEFT JOIN whose optional side is the parent, or a join in one subquery" do
    [
      "SELECT fx.users.id FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id",
      "SELECT fx.posts.id FROM fx.posts LEFT JOIN fx.users ON fx.posts.user_id = fx.users.id",
      "SELECT 1 FROM fx.users u WHERE u.id IN (SELECT fx.posts.user_id FROM fx.posts, fx.users " \
      "WHERE fx.posts.user_id = fx.users.id)"
    ].each { |sql| expect(childless_users(sql)).to eq([]), sql }
  end
end
