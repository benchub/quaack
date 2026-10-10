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

  it "builds a user with no post for a RIGHT JOIN's left side, and either side of a FULL JOIN" do
    [
      "SELECT fx.users.id FROM fx.posts RIGHT JOIN fx.users ON fx.posts.user_id = fx.users.id",
      "SELECT fx.users.id FROM fx.posts FULL JOIN fx.users ON fx.posts.user_id = fx.users.id",
      "SELECT fx.users.id FROM fx.users FULL JOIN fx.posts ON fx.posts.user_id = fx.users.id"
    ].each { |sql| expect(childless_users(sql).size).to eq(1), sql }
  end

  it "builds none for a RIGHT JOIN whose optional side is the parent, or a join in a derived table" do
    [
      "SELECT fx.posts.id FROM fx.users RIGHT JOIN fx.posts ON fx.posts.user_id = fx.users.id",
      "SELECT x.id FROM fx.users x LEFT JOIN (SELECT fx.posts.id FROM fx.posts, fx.users " \
      "WHERE fx.posts.user_id = fx.users.id) d ON true"
    ].each { |sql| expect(childless_users(sql)).to eq([]), sql }
  end

  it "builds none for an inner join, a LEFT JOIN whose optional side is the parent, or a join in one subquery" do
    [
      "SELECT fx.users.id FROM fx.users JOIN fx.posts ON fx.posts.user_id = fx.users.id",
      "SELECT fx.posts.id FROM fx.posts LEFT JOIN fx.users ON fx.posts.user_id = fx.users.id",
      "SELECT 1 FROM fx.users u WHERE u.id IN (SELECT fx.posts.user_id FROM fx.posts, fx.users " \
      "WHERE fx.posts.user_id = fx.users.id)"
    ].each { |sql| expect(childless_users(sql)).to eq([]), sql }
  end
  # 20261010-35.
  it "builds a user with no post for a LATERAL subquery that correlates to it" do
    [
      "SELECT fx.users.id FROM fx.users LEFT JOIN LATERAL (SELECT fx.posts.id FROM fx.posts " \
      "WHERE fx.posts.user_id = fx.users.id) s ON true WHERE s.id IS NULL",
      "SELECT fx.users.id, s.id FROM fx.users CROSS JOIN LATERAL (SELECT fx.posts.id FROM fx.posts " \
      "WHERE fx.posts.user_id = fx.users.id ORDER BY fx.posts.score LIMIT 1) s"
    ].each { |sql| expect(childless_users(sql).size).to eq(1), sql }
  end

  it "builds none for a LEFT JOIN whose WHERE rejects NULLs on the optional side" do
    [
      "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
      "WHERE fx.posts.score > 1",
      "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts p ON p.user_id = fx.users.id " \
      "WHERE fx.users.state = 'a' AND p.score IN (1, 2)"
    ].each { |sql| expect(childless_users(sql)).to eq([]), sql }
  end

  it "keeps it when the WHERE might pass NULLs on the optional side" do
    [
      "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
      "WHERE fx.posts.score > 1 OR fx.users.state = 'a'",
      "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
      "WHERE fx.users.state = 'a'",
      "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
      "WHERE coalesce(fx.posts.score, 0) = 0",
      "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
      "WHERE fx.posts.score IS DISTINCT FROM 1",
      "SELECT fx.users.id FROM fx.users LEFT JOIN fx.posts ON fx.posts.user_id = fx.users.id " \
      "WHERE fx.users.id IN (SELECT fx.posts.user_id FROM fx.posts WHERE fx.posts.score > 1)"
    ].each { |sql| expect(childless_users(sql).size).to be >= 1, sql }
  end

  it "gives some user more posts than a correlated count's threshold" do
    sql = "SELECT fx.users.id FROM fx.users WHERE (SELECT count(*) FROM fx.posts " \
          "WHERE fx.posts.user_id = fx.users.id) > 2"
    expect(rows(sql, "posts").map { it["user_id"] }.tally.values.max).to eq(3)
    expect(childless_users(sql).size).to eq(1)
    both = "#{sql} AND NOT EXISTS (SELECT 1 FROM fx.posts WHERE fx.posts.user_id = fx.users.id AND fx.posts.score > 5)"
    expect(rows(both, "posts").map { it["user_id"] }.tally.values.max).to eq(3)
  end

  it "builds no extra posts for a threshold past the bound" do
    far = "SELECT fx.users.id FROM fx.users WHERE (SELECT count(*) FROM fx.posts " \
          "WHERE fx.posts.user_id = fx.users.id) > 50"
    expect(rows(far, "posts").map { it["user_id"] }.tally.values.max).to eq(1)
  end

  it "builds an a with no b for a LEFT JOIN on a composite foreign key" do
    conn.exec("CREATE TABLE fx.a (x int, y int, PRIMARY KEY (x, y)); " \
              "CREATE TABLE fx.b (id int PRIMARY KEY, x int NOT NULL, y int NOT NULL, " \
              "FOREIGN KEY (x, y) REFERENCES fx.a)")
    sql = "SELECT fx.a.x FROM fx.a LEFT JOIN fx.b ON fx.b.x = fx.a.x AND fx.b.y = fx.a.y WHERE fx.b.id IS NULL"
    pairs = rows(sql, "b").map { [it["x"], it["y"]] }
    expect(rows(sql, "a").count { !pairs.include?([it["x"], it["y"]]) }).to eq(1)
  end

  it "builds a person no one reports to for a self-reference under another alias, and none for an inner one" do
    conn.exec("CREATE TABLE fx.people (id bigint PRIMARY KEY, boss_id bigint REFERENCES fx.people)")
    unreported = lambda do |sql|
      people = rows(sql, "people")
      people.count { |p| people.none? { it["boss_id"] == p["id"] } }
    end
    [
      "SELECT p.id FROM fx.people p WHERE NOT EXISTS (SELECT 1 FROM fx.people r WHERE r.boss_id = p.id)",
      "SELECT p.id, r.id FROM fx.people p LEFT JOIN fx.people r ON r.boss_id = p.id"
    ].each { |sql| expect(unreported.call(sql)).to eq(1), sql }
    expect(unreported.call("SELECT p.id FROM fx.people p JOIN fx.people r ON r.boss_id = p.id")).to eq(0)
  end
end
