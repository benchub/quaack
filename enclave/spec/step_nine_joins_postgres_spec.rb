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

  # comments.id is a key, since parent_comment_id references it, so a copy
  # of a comment needs its own id to give its user a second comment.
  it "disproves a JOIN that returns a user once per comment as EXISTS, and the reverse" do
    join = "SELECT u.id, u.name FROM fx.users u JOIN fx.comments c ON c.user_id = u.id"
    exists = "SELECT u.id, u.name FROM fx.users u WHERE EXISTS (SELECT 1 FROM fx.comments c WHERE c.user_id = u.id)"
    expect(verdicts(join, "SELECT u.id, u.name FROM fx.users u, fx.comments c WHERE c.user_id = u.id", exists))
      .to eq([[true, nil], [false, :s3]])
    expect(verdicts(exists, "SELECT u.id, u.name FROM fx.users u WHERE u.id IN (SELECT c.user_id FROM fx.comments c)",
                    join))
      .to eq([[true, nil], [false, :s3]])
  end
end
