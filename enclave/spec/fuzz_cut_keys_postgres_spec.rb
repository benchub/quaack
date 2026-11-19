# frozen_string_literal: true

require "quaack/enclave/fuzz"

# Cut cycle keys load deferred and are checked at the end of each world
# (task 20261119-001202-1): a dangling cut-key value fails to load, and a
# cut key a partition inherits is made deferrable where it was declared.
RSpec.describe Quaack::Enclave::Fuzz do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:fuzz) { described_class }

  def table(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  def row(name, cells) = fuzz::Generator::Row.new(table(name), cells)

  describe "a world with a dangling cut key" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA fx;
        CREATE TABLE fx.accounts (id integer PRIMARY KEY, course_template_id integer);
        CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts);
        ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
      SQL
    end

    let(:catalog) { fuzz::Catalog.new(conn, [table("accounts"), table("courses")]) }
    let(:cut) { catalog.kept.select { it.columns == ["course_template_id"] } }

    def loads?(template)
      loader = fuzz::Session::Loader.new(conn, catalog, [], cut:)
      conn.exec("BEGIN")
      loader.prepare
      conn.exec("SAVEPOINT quaack_base")
      loader.load([row("accounts", { "id" => "1", "course_template_id" => template }),
                   row("courses", { "id" => "7", "account_id" => "1" })])
    ensure
      conn.exec("ROLLBACK")
    end

    it "finds the cut key" do
      expect(cut.size).to eq(1)
    end

    it "loads when the cut key points to a later row" do
      expect(loads?("7")).to be(true)
    end

    it "fails to load when the cut key points to no row" do
      expect(loads?("99")).to be(false)
    end
  end

  describe "a cut key a partition inherits" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA fx;
        CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL);
        CREATE TABLE fx.accounts (id integer, course_template_id integer REFERENCES fx.courses,
          PRIMARY KEY (id)) PARTITION BY RANGE (id);
        CREATE TABLE fx.accounts_p PARTITION OF fx.accounts FOR VALUES FROM (MINVALUE) TO (MAXVALUE);
        ALTER TABLE fx.courses ADD FOREIGN KEY (account_id) REFERENCES fx.accounts_p;
      SQL
    end

    it "disproves a dropped where.missing anti join on it" do
      original = "SELECT a.id FROM fx.accounts_p a LEFT JOIN fx.courses c ON c.id = a.course_template_id " \
                 "WHERE c.id IS NULL ORDER BY a.id"
      verdict = fuzz.run(conn, original, "SELECT a.id FROM fx.accounts_p a ORDER BY a.id",
                         stop: fuzz::StopRule.trials(300)).verdict
      expect(verdict).to eq(:disproved)
    end

    it "disproves it when the parent is in the footprint too" do
      where = "WHERE c.id IS NULL AND EXISTS (SELECT 1 FROM fx.accounts) ORDER BY a.id"
      original = "SELECT a.id FROM fx.accounts_p a LEFT JOIN fx.courses c ON c.id = a.course_template_id #{where}"
      candidate = "SELECT a.id FROM fx.accounts_p a WHERE EXISTS (SELECT 1 FROM fx.accounts) ORDER BY a.id"
      expect(fuzz.run(conn, original, candidate, stop: fuzz::StopRule.trials(300)).verdict).to eq(:disproved)
    end
  end
end
