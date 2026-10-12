# frozen_string_literal: true

require "quaack/enclave/deadline"
require "quaack/enclave/denormalized_fixture"
require "quaack/enclave/fuzz"
require "quaack/enclave/table_name"

# rewrite-test's fuzz search (task 20261012-2, DESIGN.md's rewrite-test):
# random small databases built around the queries' own tables and values,
# compared through the official comparison, a counterexample shrunk and then
# lifted with every constraint enforced.
RSpec.describe Quaack::Enclave::Fuzz do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:stop) { Quaack::Enclave::Fuzz::StopRule.trials(150) }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA s;
      CREATE TABLE s.customers (id integer PRIMARY KEY, name text NOT NULL);
      CREATE TABLE s.orders (id integer PRIMARY KEY, customer_id integer NOT NULL REFERENCES s.customers,
                             status text NOT NULL CHECK (status IN ('new', 'shipped', 'lost')), total numeric);
    SQL
  end

  def fuzz(original, candidate, **) = described_class.run(conn, original, candidate, stop:, **)

  def foreign_keys
    conn.exec("SELECT conname FROM pg_constraint WHERE contype = 'f' AND conrelid = 's.orders'::regclass").values
  end

  it "disproves a wrong rewrite with a lifted counterexample, and gives its size per table, never its rows" do
    outcome = fuzz("SELECT id FROM s.orders WHERE status = 'shipped' AND total > 100",
                   "SELECT id FROM s.orders WHERE status = 'shipped' AND total >= 100")

    expect(outcome).to have_attributes(verdict: :disproved, rule: :row_count, sizes: [["s", "orders", 1]])
  end

  it "stops at once on a lifted counterexample, well before the floor" do
    outcome = fuzz("SELECT id FROM s.orders WHERE status = 'shipped' AND total > 100",
                   "SELECT id FROM s.orders WHERE total > 100")

    expect(outcome.verdict).to eq(:disproved)
    expect(outcome.trials).to be_between(1, 149)
  end

  it "passes a sound rewrite once the stop rule says so, counting the worlds both queries ran on" do
    outcome = fuzz("SELECT id FROM s.orders WHERE status = 'shipped' AND total > 100",
                   "SELECT id FROM s.orders WHERE total > 100 AND status = 'shipped'")

    expect(outcome).to have_attributes(verdict: :passed, rule: nil, sizes: [])
    expect(outcome.trials).to be >= 150
  end

  it "searches with the footprint's outside foreign keys dropped, and leaves the arena as it was" do
    fuzz("SELECT id FROM s.orders WHERE total > 1", "SELECT id FROM s.orders WHERE total >= 1")

    expect(foreign_keys).to eq([["orders_customer_id_fkey"]])
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "counts only a counterexample that also holds with every constraint enforced" do
    # No customer can exist, so no order can either: the rewrite is wrong
    # only in worlds the dropped foreign key allows.
    conn.exec("ALTER TABLE s.customers ADD CHECK (id < 0 AND id > 0)")

    outcome = fuzz("SELECT id FROM s.orders WHERE total > 100", "SELECT id FROM s.orders WHERE total >= 100")

    expect(outcome).to have_attributes(verdict: :passed, rule: nil, sizes: [])
  end

  it "is untested when the queries read no table" do
    expect(fuzz("SELECT 1", "SELECT 2")).to have_attributes(verdict: :untested, trials: 0, sizes: [])
  end

  it "refuses a query that names a table without its schema, whose footprint it can't read" do
    expect { fuzz("SELECT id FROM orders", "SELECT id FROM s.orders") }.to raise_error(Quaack::Enclave::Fuzz::Error)
  end

  it "reads a CTE's name as the CTE's, not a table without its schema" do
    outcome = fuzz("WITH o AS (SELECT id, total FROM s.orders) SELECT id FROM o WHERE total > 100",
                   "WITH o AS (SELECT id, total FROM s.orders) SELECT id FROM o WHERE total >= 100")

    expect(outcome.verdict).to eq(:disproved)
  end

  it "is untested when no world is one the original runs on" do
    outcome = fuzz("SELECT id, 1 / 0 FROM s.orders", "SELECT id, 2 FROM s.orders")

    expect(outcome).to have_attributes(verdict: :untested, trials: 0)
  end

  it "takes a world the original fails on as one it needn't answer, not a disproof" do
    outcome = fuzz("SELECT id FROM s.orders WHERE 10 / total > 1",
                   "SELECT id FROM s.orders WHERE total > 0 AND total < 10")

    expect(outcome.verdict).to eq(:passed)
  end

  it "gives the same outcome every time it counts trials" do
    pair = ["SELECT id FROM s.orders WHERE status = 'lost' OR total < 5", "SELECT id FROM s.orders WHERE total < 5"]

    expect(fuzz(*pair)).to eq(fuzz(*pair))
  end

  it "ends with what it has when the rewrite's deadline runs out" do
    ticks = 0
    deadline = Quaack::Enclave::Deadline.new(40, clock: -> { ticks += 1 })
    outcome = Quaack::Enclave::Deadline.within(deadline) do
      fuzz("SELECT id FROM s.orders WHERE total > 100", "SELECT id FROM s.orders WHERE 100 < total")
    end

    expect(outcome.verdict).to eq(:passed)
    expect(outcome.trials).to be_between(1, 149)
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "refuses a query that isn't one SELECT before it touches the arena" do
    expect { fuzz("SELECT id FROM s.orders", "DELETE FROM s.orders") }
      .to raise_error(Quaack::Enclave::ArenaRunner::Error) { expect(it.rule).to eq(:statement_not_allowed) }
  end

  context "with a rule's denormalized_equal assumption" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA cv;
        CREATE TABLE cv.courses (id bigint PRIMARY KEY);
        CREATE TABLE cv.assignments (id bigint PRIMARY KEY, context_type text NOT NULL, context_id bigint NOT NULL);
        CREATE TABLE cv.submissions (id bigint PRIMARY KEY, assignment_id bigint REFERENCES cv.assignments,
                                     course_id bigint REFERENCES cv.courses);
      SQL
    end

    let(:copy) do
      table = ->(name) { Quaack::Enclave::TableName.new(schema: "cv", name:) }
      Quaack::Enclave::DenormalizedFixture::Copy.new(
        table: table.call("submissions"), column: "course_id", join_column: "assignment_id",
        references_table: table.call("assignments"),
        references_column: "id", type_column: "context_type", type_value: "Course", id_column: "context_id"
      )
    end
    let(:pair) do
      ["SELECT s.id FROM cv.submissions s JOIN cv.assignments a ON a.id = s.assignment_id " \
       "WHERE a.context_type = 'Course' AND a.context_id = 7",
       "SELECT s.id FROM cv.submissions s JOIN cv.assignments a ON a.id = s.assignment_id " \
       "WHERE a.context_type = 'Course' AND s.course_id = 7"]
    end

    it "keeps the copy in every world, so the rewrite that rests on it passes" do
      outcome = fuzz(*pair, honour: [copy])

      # The whole floor: a world that broke the copy would be a kill that
      # can't lift, and the search gives up after a few of those.
      expect(outcome).to have_attributes(verdict: :passed, rule: nil)
      expect(outcome.trials).to be >= 150
    end

    it "disproves the same rewrite when it's not told to keep the copy" do
      expect(fuzz(*pair).verdict).to eq(:disproved)
    end

    it "keeps the copy when it lifts a counterexample too" do
      row = Quaack::Enclave::Fuzz::Generator::Row
      table = ->(name) { Quaack::Enclave::TableName.new(schema: "cv", name:) }
      tables = %w[submissions assignments].map { table.call(it) }
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, tables)
      domains = Quaack::Enclave::Fuzz::Domains.new(conn, catalog, pair)
      world = [row.new(table.call("assignments"), { "id" => "1", "context_type" => "Course", "context_id" => "7" }),
               row.new(table.call("submissions"), { "id" => "1", "assignment_id" => "1", "course_id" => "8" })]
      lift = ->(honour) { Quaack::Enclave::Fuzz::Lift.new(conn, catalog, domains, honour:, statement_timeout_ms: 5000) }

      expect(lift.call([]).call(world, original: pair[0], candidate: pair[1])).to eq(:row_count)
      expect(lift.call([copy]).call(world, original: pair[0], candidate: pair[1])).to be_nil
    end
  end

  context "with parents whose tables reference each other through a nullable foreign key" do
    # Canvas's shape: accounts.course_template_id points at courses, and
    # courses.account_id at accounts. The built account leaves its
    # course_template_id NULL, so it must load before the course.
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA cy;
        CREATE TABLE cy.accounts (id bigint PRIMARY KEY, course_template_id bigint);
        CREATE TABLE cy.courses (id bigint PRIMARY KEY, account_id bigint NOT NULL REFERENCES cy.accounts);
        ALTER TABLE cy.accounts ADD FOREIGN KEY (course_template_id) REFERENCES cy.courses;
        CREATE TABLE cy.sections (id bigint PRIMARY KEY, course_id bigint NOT NULL REFERENCES cy.courses);
      SQL
    end

    it "loads each built parent after the parents its row references" do
      pair = ["SELECT id FROM cy.sections WHERE id > 1", "SELECT id FROM cy.sections WHERE id >= 1"]
      sections = Quaack::Enclave::TableName.new(schema: "cy", name: "sections")
      catalog = Quaack::Enclave::Fuzz::Catalog.new(conn, [sections])
      domains = Quaack::Enclave::Fuzz::Domains.new(conn, catalog, pair)
      world = [Quaack::Enclave::Fuzz::Generator::Row.new(sections, { "id" => "1", "course_id" => "7" })]
      lift = Quaack::Enclave::Fuzz::Lift.new(conn, catalog, domains, honour: [], statement_timeout_ms: 5000)

      expect(lift.call(world, original: pair[0], candidate: pair[1])).to eq(:row_count)
    end
  end
end
