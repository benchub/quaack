# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"

# Scenarios for ordinary queries that pin a join key (20261010-21's review,
# 20261010-25): each group takes its own id, and S0 to S6 load and hold
# what they should.
RSpec.describe Quaack::Enclave::Scenarios do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.users (id bigint PRIMARY KEY, state text NOT NULL);
      CREATE TABLE fx.posts (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
        parent_id bigint REFERENCES fx.posts);
      CREATE TABLE fx.comments (id bigint PRIMARY KEY, post_id bigint NOT NULL REFERENCES fx.posts);
    SQL
  end

  def build(sql) = described_class.build(conn, PgQuery.parse(sql))

  def ids(rows, table) = rows.select { it.table.name == table }.map { Integer(it.values[it.columns.index("id")]) }

  # S5's hit and its two boundary groups all pass the list, so each needs
  # a list value of its own, or two collide and one is left out.
  it "gives each group under posts.id IN (1, 2, 3) an id of its own" do
    scenarios = build("SELECT * FROM fx.posts WHERE fx.posts.id IN (1, 2, 3)")
    expect(ids(scenarios[:s5], "posts") & [1, 2, 3]).to contain_exactly(1, 2, 3)
    s1 = ids(scenarios[:s1], "posts")
    expect(s1.size).to eq(2)
    expect(s1 - [1, 2, 3]).not_to be_empty
  end

  {
    "an IN list on a parent's key" =>
      "SELECT fx.posts.id FROM fx.posts JOIN fx.users ON fx.users.id = fx.posts.user_id WHERE fx.users.id IN (1, 2, 3)",
    "an equality on a key" => "SELECT * FROM fx.posts WHERE fx.posts.id = 5",
    "a foreign-key chain" =>
      "SELECT fx.comments.id FROM fx.comments JOIN fx.posts ON fx.posts.id = fx.comments.post_id " \
      "JOIN fx.users ON fx.users.id = fx.posts.user_id WHERE fx.users.id = 4",
    "a self-reference" =>
      "SELECT q.id FROM fx.posts p JOIN fx.posts q ON q.parent_id = p.id WHERE p.id = 9"
  }.each do |shape, sql|
    it "builds S0 to S6 for #{shape}: S0 empty, every other one loads with unique ids and the hit's row" do
      scenarios = build(sql)
      expect(scenarios.keys).to eq(described_class::NAMES)
      expect(scenarios[:s0]).to eq([])
      scenarios.except(:s0).each do |name, rows|
        %w[users posts comments].each do |table|
          expect(ids(rows, table).uniq.size).to eq(ids(rows, table).size), "#{name} repeats a #{table} id"
        end
        found = runner.with_fixture(rows) { |tx| tx.query(sql).rows.size }
        expect(found).to be_positive, "#{name} holds no row the query returns"
      end
    end
  end
end
