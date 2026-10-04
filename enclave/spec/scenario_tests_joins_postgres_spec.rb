# frozen_string_literal: true

require "quaack/enclave/scenario_tests"

# rewrite-test on ordinary joins that apps and ORMs write: an anti-join on a
# self-referencing foreign key, a JOIN against EXISTS, and a foreign key
# that need not point at the parent its row's other keys lead to. Each
# wrong rewrite is disproved, and its correct twin passes.
RSpec.describe Quaack::Enclave::ScenarioTests do
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

  # tags.name is unique, and taggings' key is its two foreign keys.
  def create_taggings
    conn.exec(<<~SQL)
      CREATE TABLE fx.posts (id bigint PRIMARY KEY, title text NOT NULL);
      CREATE TABLE fx.tags (id bigint PRIMARY KEY, name text NOT NULL UNIQUE);
      CREATE TABLE fx.taggings (post_id bigint NOT NULL REFERENCES fx.posts, tag_id bigint NOT NULL REFERENCES fx.tags,
        PRIMARY KEY (post_id, tag_id));
    SQL
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

  # tasks.id is a key, since parent_task_id references it, and tasks has
  # no foreign key a row can point across groups (tenant_id is in two), so
  # only a copy with its own id gives a project its second task.
  it "disproves a JOIN on a composite key that returns a project once per task as EXISTS" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.tenants (id bigint PRIMARY KEY);
      CREATE TABLE fx.projects (tenant_id bigint NOT NULL REFERENCES fx.tenants, id bigint,
        PRIMARY KEY (tenant_id, id));
      CREATE TABLE fx.tasks (id bigint PRIMARY KEY, tenant_id bigint NOT NULL REFERENCES fx.tenants,
        project_id bigint NOT NULL, parent_task_id bigint REFERENCES fx.tasks,
        FOREIGN KEY (tenant_id, project_id) REFERENCES fx.projects);
    SQL
    join = "SELECT p.id FROM fx.projects p JOIN fx.tasks t ON t.tenant_id = p.tenant_id AND t.project_id = p.id"
    expect(verdicts(join, "SELECT p.id FROM fx.projects p, fx.tasks t WHERE t.tenant_id = p.tenant_id " \
                          "AND t.project_id = p.id",
                    "SELECT p.id FROM fx.projects p WHERE EXISTS (SELECT 1 FROM fx.tasks t " \
                    "WHERE t.tenant_id = p.tenant_id AND t.project_id = p.id)"))
      .to eq([[true, nil], [false, :s3]])
  end

  # list_items' key is its foreign key columns and position. A copy keeps
  # the hit's tenant and list, and takes a position of its own, so the list
  # gets a second item. tenant_id is in two foreign keys, so no row points
  # across groups to give it one.
  it "disproves a JOIN that returns a list once per item as EXISTS when the item's key holds its foreign key" do
    conn.exec(<<~SQL)
      CREATE TABLE fx.tenants (id bigint PRIMARY KEY);
      CREATE TABLE fx.lists (tenant_id bigint NOT NULL REFERENCES fx.tenants, id bigint, PRIMARY KEY (tenant_id, id));
      CREATE TABLE fx.list_items (tenant_id bigint NOT NULL REFERENCES fx.tenants, list_id bigint NOT NULL,
        position integer NOT NULL, PRIMARY KEY (tenant_id, list_id, position),
        FOREIGN KEY (tenant_id, list_id) REFERENCES fx.lists);
    SQL
    join = "SELECT l.id FROM fx.lists l JOIN fx.list_items i ON i.tenant_id = l.tenant_id AND i.list_id = l.id"
    expect(verdicts(join, "SELECT l.id FROM fx.lists l, fx.list_items i WHERE i.tenant_id = l.tenant_id " \
                          "AND i.list_id = l.id",
                    "SELECT l.id FROM fx.lists l WHERE EXISTS (SELECT 1 FROM fx.list_items i " \
                    "WHERE i.tenant_id = l.tenant_id AND i.list_id = l.id)"))
      .to eq([[true, nil], [false, :s3]])
  end

  # tags.name is unique, so S6's many group can't take the hit's 'ruby' and
  # is left out. Its copies' rows that point at its post or tag must go
  # with it, or the load fails.
  it "passes a correct rewrite of a filter on a unique parent column joined through a child" do
    create_taggings
    original = "SELECT p.id, p.title FROM fx.posts p JOIN fx.taggings t ON t.post_id = p.id " \
               "JOIN fx.tags tg ON tg.id = t.tag_id WHERE tg.name = 'ruby' ORDER BY p.id"
    results = described_class.run(conn, original, [
                                    "SELECT p.id, p.title FROM fx.posts p WHERE EXISTS (SELECT 1 " \
                                    "FROM fx.taggings t JOIN fx.tags tg ON tg.id = t.tag_id " \
                                    "WHERE t.post_id = p.id AND tg.name = 'ruby') ORDER BY p.id",
                                    "SELECT p.id, p.title FROM fx.posts p JOIN fx.taggings t ON t.post_id = p.id " \
                                    "ORDER BY p.id"
                                  ]).results
    expect(results.map { |r| [r.passed, r.scenario, r.rule] }).to eq([[true, nil, nil], [false, :s1, :row_count]])
  end

  # tags.name is unique, so a group that needs a second tag the filter
  # takes must give it the filter's other name, not repeat the hit's.
  it "disproves EXISTS for a JOIN that returns a post once per tag the filter takes" do
    create_taggings
    join = "SELECT p.id FROM fx.posts p JOIN fx.taggings t ON t.post_id = p.id " \
           "JOIN fx.tags tg ON tg.id = t.tag_id WHERE tg.name IN ('ruby', 'rails') ORDER BY p.id"
    expect(verdicts(join, "SELECT p.id FROM fx.posts p, fx.taggings t, fx.tags tg WHERE t.post_id = p.id " \
                          "AND tg.id = t.tag_id AND tg.name IN ('ruby', 'rails') ORDER BY p.id",
                    "SELECT p.id FROM fx.posts p WHERE EXISTS (SELECT 1 FROM fx.taggings t JOIN fx.tags tg " \
                    "ON tg.id = t.tag_id WHERE t.post_id = p.id AND tg.name IN ('ruby', 'rails')) ORDER BY p.id"))
      .to eq([[true, nil], [false, :s3]])
  end

  # The cross that gives the hit's tag a second post needs no tag of its
  # own, so the filter's names, all taken, don't keep it out.
  it "disproves EXISTS for a JOIN that returns a tag once per post when the tag's name is unique" do
    create_taggings
    join = "SELECT tg.id FROM fx.tags tg JOIN fx.taggings t ON t.tag_id = tg.id WHERE tg.name IN ('ruby', 'rails') " \
           "ORDER BY tg.id"
    expect(verdicts(join, "SELECT tg.id FROM fx.tags tg, fx.taggings t WHERE t.tag_id = tg.id " \
                          "AND tg.name IN ('ruby', 'rails') ORDER BY tg.id",
                    "SELECT tg.id FROM fx.tags tg WHERE EXISTS (SELECT 1 FROM fx.taggings t WHERE t.tag_id = tg.id) " \
                    "AND tg.name IN ('ruby', 'rails') ORDER BY tg.id"))
      .to eq([[true, nil], [false, :s3]])
  end

  # t.id is a NOT NULL key, so no value satisfies t.id IS NULL, and a group
  # whose templates row needs one can't be built. Rows of other groups that
  # point at its account must not be left behind (20261003-32).
  it "loads every scenario for an anti-join beside an inner join" do
    conn.exec("CREATE TABLE fx.templates (id bigint PRIMARY KEY, account_id bigint NOT NULL REFERENCES fx.accounts)")
    sql = "SELECT c.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id " \
          "LEFT JOIN fx.templates t ON t.account_id = a.id WHERE t.id IS NULL ORDER BY c.id"
    expect(verdicts(sql, sql, "SELECT c.id FROM fx.courses c WHERE NOT EXISTS (SELECT 1 FROM fx.templates t " \
                              "WHERE t.account_id = c.account_id) ORDER BY c.id",
                    "SELECT c.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id ORDER BY c.id"))
      .to eq([[true, nil], [true, nil], [false, :s1]])
  end
end
