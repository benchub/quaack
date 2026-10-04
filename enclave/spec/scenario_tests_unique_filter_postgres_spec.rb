# frozen_string_literal: true

require "quaack/enclave/scenario_tests"

# rewrite-test on a filter that pins a unique parent column (email = 'a@b') with
# a join to a child. Only one row can take the value, so the parent row
# with no child that tells the join from its absence can't sit beside the
# hit. It goes in another fixture of the same scenario, and a rewrite that
# drops the join is disproved, not passed. Task 20261003-40.
RSpec.describe Quaack::Enclave::ScenarioTests do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.users (id bigint PRIMARY KEY, email text NOT NULL UNIQUE);
      CREATE TABLE fx.profiles (id bigint PRIMARY KEY, user_id bigint NOT NULL UNIQUE REFERENCES fx.users, bio text);
      CREATE TABLE fx.posts (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
        slug text NOT NULL UNIQUE);
      CREATE TABLE fx.comments (id bigint PRIMARY KEY, post_id bigint NOT NULL REFERENCES fx.posts, body text);
      CREATE TABLE fx.tags (id bigint PRIMARY KEY, name text NOT NULL UNIQUE);
      CREATE TABLE fx.taggings (post_id bigint NOT NULL REFERENCES fx.posts, tag_id bigint NOT NULL REFERENCES fx.tags,
        PRIMARY KEY (post_id, tag_id));
      CREATE TABLE fx.messages (id bigint PRIMARY KEY, sender_id bigint NOT NULL REFERENCES fx.users,
        recipient_id bigint NOT NULL REFERENCES fx.users);
    SQL
  end

  def passes(original, *candidates) = described_class.run(conn, original, candidates).results.map(&:passed)

  it "disproves dropping an inner join to a has-one child" do
    expect(passes("SELECT u.id FROM fx.users u JOIN fx.profiles pr ON pr.user_id = u.id " \
                  "WHERE u.email = 'a@b' ORDER BY u.id",
                  "SELECT u.id FROM fx.users u WHERE u.email = 'a@b' " \
                  "AND EXISTS (SELECT 1 FROM fx.profiles pr WHERE pr.user_id = u.id) ORDER BY u.id",
                  "SELECT u.id FROM fx.users u WHERE u.email = 'a@b' ORDER BY u.id",
                  "SELECT u.id FROM fx.users u LEFT JOIN fx.profiles pr ON pr.user_id = u.id " \
                  "WHERE u.email = 'a@b' ORDER BY u.id"))
      .to eq([true, false, false])
  end

  it "disproves dropping a DISTINCT join to has-many children" do
    expect(passes("SELECT DISTINCT u.id FROM fx.users u JOIN fx.posts p ON p.user_id = u.id " \
                  "WHERE u.email = 'a@b' ORDER BY u.id",
                  "SELECT u.id FROM fx.users u WHERE u.email = 'a@b' " \
                  "AND EXISTS (SELECT 1 FROM fx.posts p WHERE p.user_id = u.id) ORDER BY u.id",
                  "SELECT DISTINCT u.id FROM fx.users u WHERE u.email = 'a@b' ORDER BY u.id"))
      .to eq([true, false])
  end

  it "disproves dropping a join from a parent that itself has a parent" do
    expect(passes("SELECT DISTINCT p.id FROM fx.posts p JOIN fx.comments c ON c.post_id = p.id " \
                  "WHERE p.slug = 'hello' ORDER BY p.id",
                  "SELECT p.id FROM fx.posts p WHERE p.slug = 'hello' " \
                  "AND EXISTS (SELECT 1 FROM fx.comments c WHERE c.post_id = p.id) ORDER BY p.id",
                  "SELECT p.id FROM fx.posts p WHERE p.slug = 'hello' ORDER BY p.id"))
      .to eq([true, false])
  end

  # Only a message from the hit's user to another tells the sender from the
  # recipient. That other user can't take the pinned email, so it takes a
  # near miss's, in a fixture of its own.
  it "disproves reading the other foreign key to the same parent" do
    expect(passes("SELECT m.id FROM fx.messages m JOIN fx.users s ON s.id = m.sender_id " \
                  "WHERE s.email = 'a@b' ORDER BY m.id",
                  "SELECT m.id FROM fx.messages m WHERE m.sender_id IN (SELECT s.id FROM fx.users s " \
                  "WHERE s.email = 'a@b') ORDER BY m.id",
                  "SELECT m.id FROM fx.messages m WHERE m.recipient_id IN (SELECT s.id FROM fx.users s " \
                  "WHERE s.email = 'a@b') ORDER BY m.id"))
      .to eq([true, false])
  end

  ["tg.name = 'ruby'", "tg.name IN ('ruby', 'rails')"].each do |filter|
    it "disproves dropping a DISTINCT join from tags to taggings on #{filter}" do
      expect(passes("SELECT DISTINCT tg.id FROM fx.tags tg JOIN fx.taggings t ON t.tag_id = tg.id " \
                    "WHERE #{filter} ORDER BY tg.id",
                    "SELECT tg.id FROM fx.tags tg WHERE #{filter} " \
                    "AND EXISTS (SELECT 1 FROM fx.taggings t WHERE t.tag_id = tg.id) ORDER BY tg.id",
                    "SELECT tg.id FROM fx.tags tg WHERE #{filter} ORDER BY tg.id"))
        .to eq([true, false])
    end
  end
end
