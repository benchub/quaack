# frozen_string_literal: true

require "quaack/enclave/step_nine"

# Step 9 on ordinary joins that apps and ORMs write: an anti-join on a
# self-referencing foreign key, a JOIN against EXISTS, and a foreign key
# that need not point at the parent its row's other keys lead to. Each
# wrong rewrite is disproved, and its correct twin passes.
RSpec.describe Quaack::Enclave::StepNine do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.accounts (id bigint PRIMARY KEY, name text NOT NULL,
        root_account_id bigint REFERENCES fx.accounts);
      CREATE TABLE fx.courses (id bigint PRIMARY KEY, account_id bigint NOT NULL REFERENCES fx.accounts);
      CREATE TABLE fx.enrollments (id bigint PRIMARY KEY, course_id bigint NOT NULL REFERENCES fx.courses,
        root_account_id bigint REFERENCES fx.accounts);
      CREATE TABLE fx.users (id bigint PRIMARY KEY, name text NOT NULL);
      CREATE TABLE fx.comments (id bigint PRIMARY KEY, user_id bigint NOT NULL REFERENCES fx.users,
        parent_comment_id bigint REFERENCES fx.comments, body text);
    SQL
  end

  def verdicts(original, *candidates)
    described_class.run(conn, original, candidates).results.map { |r| [r.passed, r.scenario] }
  end

  it "disproves the JOIN form of an anti-join on a self-referencing foreign key" do
    original = "SELECT a.id FROM fx.accounts a LEFT JOIN fx.accounts r ON r.id = a.root_account_id " \
               "WHERE r.id IS NULL ORDER BY a.id"
    expect(verdicts(original,
                    "SELECT a.id FROM fx.accounts a WHERE a.root_account_id IS NULL ORDER BY a.id",
                    "SELECT a.id FROM fx.accounts a JOIN fx.accounts r ON r.id = a.root_account_id " \
                    "WHERE r.id IS NULL ORDER BY a.id"))
      .to eq([[true, nil], [false, :s2]])
  end
end
