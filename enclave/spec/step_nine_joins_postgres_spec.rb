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

  # enrollments.root_account_id and courses.account_id both lead to
  # accounts, and in each group to the same account.
  it "disproves a rewrite that assumes a foreign key points at the parent the row's other keys lead to" do
    expect(verdicts("SELECT e.id FROM fx.enrollments e JOIN fx.accounts a ON a.id = e.root_account_id ORDER BY e.id",
                    "SELECT e.id FROM fx.enrollments e WHERE e.root_account_id IS NOT NULL ORDER BY e.id",
                    "SELECT e.id FROM fx.enrollments e JOIN fx.courses c ON c.id = e.course_id " \
                    "WHERE e.root_account_id = c.account_id ORDER BY e.id"))
      .to eq([[true, nil], [false, :s3]])
    expect(verdicts("SELECT a.id FROM fx.accounts a WHERE a.id IN (SELECT e.root_account_id FROM fx.enrollments e) " \
                    "ORDER BY a.id",
                    "SELECT a.id FROM fx.accounts a WHERE EXISTS (SELECT 1 FROM fx.enrollments e " \
                    "WHERE e.root_account_id = a.id) ORDER BY a.id",
                    "SELECT DISTINCT a.id FROM fx.accounts a JOIN fx.courses c ON c.account_id = a.id " \
                    "JOIN fx.enrollments e ON e.course_id = c.id WHERE e.root_account_id IS NOT NULL ORDER BY a.id"))
      .to eq([[true, nil], [false, :s3]])
  end

  # tasks.tenant_id is in two foreign keys. Pointing it at another group's
  # tenant would break the composite one, so every scenario must still
  # load and the query passes itself.
  it "loads every scenario when a foreign key shares a column with a composite one" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.tenants (id bigint PRIMARY KEY);
      CREATE TABLE fx.projects (tenant_id bigint NOT NULL REFERENCES fx.tenants, id bigint,
        PRIMARY KEY (tenant_id, id));
      CREATE TABLE fx.tasks (id bigint PRIMARY KEY, tenant_id bigint NOT NULL REFERENCES fx.tenants,
        project_id bigint NOT NULL, FOREIGN KEY (tenant_id, project_id) REFERENCES fx.projects);
    SQL
    sql = "SELECT t.id FROM fx.tasks t JOIN fx.projects p ON p.tenant_id = t.tenant_id AND p.id = t.project_id"
    expect(verdicts(sql, sql)).to eq([[true, nil]])
  end
end
