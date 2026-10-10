# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/scenario_tests"
require "quaack/enclave/scenarios"

# rewrite-test on schemas where one table's rows point at each other, or
# two foreign keys reach one parent: comment trees, category trees, and
# messages with a sender and a recipient. Each wrong rewrite is disproved,
# and its correct twin passes.
RSpec.describe Quaack::Enclave::ScenarioTests do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.users (id bigint PRIMARY KEY, name text NOT NULL, email text NOT NULL);
      CREATE TABLE fx.comments (id bigint PRIMARY KEY, user_id bigint NOT NULL, body text NOT NULL,
        parent_id bigint REFERENCES fx.comments);
      CREATE TABLE fx.categories (id bigint PRIMARY KEY, label text NOT NULL, parent_id bigint REFERENCES fx.categories);
      CREATE TABLE fx.messages (id bigint PRIMARY KEY, sender_id bigint NOT NULL REFERENCES fx.users,
        recipient_id bigint NOT NULL REFERENCES fx.users);
      CREATE TABLE fx.profiles (id bigint PRIMARY KEY, user_id bigint NOT NULL UNIQUE REFERENCES fx.users,
        bio text NOT NULL);
    SQL
  end

  def verdicts(original, *candidates)
    described_class.run(conn, original, candidates).results.map { |r| [r.passed, r.scenario] }
  end

  let(:by_parent) do
    "SELECT c.id FROM fx.comments c JOIN fx.comments p ON p.id = c.parent_id WHERE p.user_id = 3 ORDER BY c.id"
  end
  let(:by_child) do
    "SELECT c.id FROM fx.comments c JOIN fx.comments p ON p.id = c.parent_id WHERE c.user_id = 3 ORDER BY c.id"
  end

  # A reply's parent is another comment, which holds the filtered user.
  it "disproves a filter on the reply for a filter on its parent in a self-join" do
    expect(verdicts(by_parent, by_child, by_parent.sub("p.id = c.parent_id", "c.parent_id = p.id")))
      .to eq([[false, :s3], [true, nil]])
  end

  it "disproves the parent's filter for the reply's, in the other direction" do
    expect(verdicts(by_child, by_parent)).to eq([[false, :s3]])
  end

  # A category tree: a category with a child, against its EXISTS form.
  it "passes the EXISTS form of a category with a child, and disproves a rewrite that drops the join" do
    join = "SELECT DISTINCT p.id FROM fx.categories p JOIN fx.categories c ON c.parent_id = p.id ORDER BY p.id"
    exists = "SELECT p.id FROM fx.categories p WHERE EXISTS (SELECT 1 FROM fx.categories c " \
             "WHERE c.parent_id = p.id) ORDER BY p.id"
    wrong = "SELECT c.id FROM fx.categories c WHERE c.parent_id IS NOT NULL ORDER BY c.id"
    expect(verdicts(join, exists, wrong)).to eq([[true, nil], [false, :s3]])
  end

  it "disproves a message's sender name for its recipient's" do
    original = "SELECT m.id, s.name, r.name FROM fx.messages m JOIN fx.users s ON s.id = m.sender_id " \
               "JOIN fx.users r ON r.id = m.recipient_id ORDER BY m.id"
    wrong = "SELECT m.id, s.name, s.name FROM fx.messages m JOIN fx.users s ON s.id = m.sender_id " \
            "JOIN fx.users r ON r.id = m.recipient_id ORDER BY m.id"
    twin = "SELECT m.id, s.name, r.name FROM fx.messages m JOIN fx.users r ON r.id = m.recipient_id " \
           "JOIN fx.users s ON s.id = m.sender_id ORDER BY m.id"
    expect(verdicts(original, wrong, twin)).to eq([[false, :s3], [true, nil]])
  end

  # profiles.user_id is unique, so a cross to the hit's user would collide
  # and be dropped. The cross takes a user of its own that has no profile
  # yet, so S3 holds a second profile, on a second user, and S1 holds one.
  it "gives S3 a second profile on a user of its own when the foreign key is unique" do
    scenarios = Quaack::Enclave::Scenarios.build(
      conn, PgQuery.parse("SELECT u.id FROM fx.users u JOIN fx.profiles p ON p.user_id = u.id")
    )
    profile_users = ->(name) { scenarios[name].select { |r| r.table.name == "profiles" }.map { |r| r.values[1] } }
    users = ->(name) { scenarios[name].select { |r| r.table.name == "users" }.map { |r| r.values[0] } }
    expect(profile_users.call(:s1).size).to eq(1)
    expect(profile_users.call(:s3).size).to eq(2)
    expect(profile_users.call(:s3).uniq.size).to eq(2)
    expect(users.call(:s3)).to include(*profile_users.call(:s3))
  end
end
