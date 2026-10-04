# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/counterexamples"
require "quaack/enclave/result_comparison"

# 10a on a schema whose foreign keys form a cycle. The LLM's inserts are
# ordered with the cycle's nullable foreign key cut, so an insert that sets
# a cut column loads with NULL there, and once every insert has loaded, an
# UPDATE sets the column to the LLM's value.
RSpec.describe Quaack::Enclave::Counterexamples do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { Quaack::Enclave::ArenaRunner.new(conn) }
  let(:map) { { "$1" => { "value" => "30", "type" => "integer" } } }

  def tn(name) = Quaack::Enclave::TableName.new(schema: "fx", name:)

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.accounts (id integer PRIMARY KEY, name text NOT NULL, course_template_id integer);
      CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts,
        title text NOT NULL);
      ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
    SQL
  end

  def prepare(*inserts)
    described_class.prepare(conn, inserts, placeholder_map: map, tables: %w[accounts courses].map { tn(it) })
  end

  let(:templates) { "SELECT a.id, a.course_template_id FROM fx.accounts a ORDER BY a.id" }

  def load(rows, inserts, sql) = runner.with_fixture(rows, inserts:) { |tx| tx.query(sql).rows }

  # Each account's template: 1's course comes from a later insert, 2's
  # from a parent row (no insert supplies course 20), 3 has none, 4's is a
  # placeholder, and 5's is its column's DEFAULT, which stays, and loads
  # since course 20 is a parent row, loaded before the inserts.
  let(:inserts) do
    ["INSERT INTO fx.courses (id, account_id, title) VALUES (10, 1, 't'), (30, 3, 'u')",
     "INSERT INTO fx.accounts (id, name, course_template_id) VALUES (1, 'a', 10), (2, 'b', 20), (3, 'c', NULL)",
     "INSERT INTO fx.accounts (id, name, course_template_id) VALUES (4, 'd', $1), (5, 'e', DEFAULT)"]
  end

  let(:expected) { [%w[1 10], %w[2 20], ["3", nil], %w[4 30], %w[5 20]] }

  before { conn.exec("ALTER TABLE fx.accounts ALTER COLUMN course_template_id SET DEFAULT 20") }

  it "keeps the LLM's value in a cut column, loaded forward" do
    prepared = prepare(*inserts)
    expect(prepared.refused).to eq([])
    expect(prepared.rows.map { it.table.name }).to eq(%w[accounts courses])
    expect(load(prepared.rows, prepared.inserts, templates).first(5)).to eq(expected)
  end

  it "keeps the LLM's value in a cut column, loaded in reverse" do
    prepared = prepare(*inserts)
    reversed = Quaack::Enclave::ResultComparison.reverse_load(prepared.rows)
    expect(load(reversed, prepared.inserts, templates).first(5)).to eq(expected)
  end

  it "matches in both load orders a candidate that's equivalent only when the values are kept" do
    prepared = prepare(*inserts)
    round = described_class.compare(
      runner, prepared,
      original: "SELECT a.id FROM fx.accounts a WHERE a.course_template_id IS NOT NULL AND a.id < 9000",
      candidate: "SELECT a.id FROM fx.accounts a WHERE a.id IN (1, 2, 4, 5)", atoms: [], untested: []
    )
    expect([round.match, round.rule, round.load_failed]).to eq([true, nil, false])
  end

  it "refuses by rule alone an insert whose cut column's value Postgres can't evaluate (20261003-24)" do
    map["$2"] = { "value" => "SENTINEL_CUT", "type" => "unknown" }
    bad = "INSERT INTO fx.accounts (id, name, course_template_id) VALUES (6, 'f', $2::integer)"
    begin
      prepared = prepare(inserts.first, bad)
    rescue StandardError => e
      raise "prepare raised, its message #{e.message.include?("SENTINEL_CUT") ? "with" : "without"} the sentinel"
    end
    expect(prepared.refused).to eq([{ index: 1, rule: "bad_value" }])
    expect([prepared.inspect, prepared.inserts.map(&:to_s), prepared.rows.map(&:values)].to_s)
      .not_to include("SENTINEL_CUT")
  end

  it "fails the load, disproving nothing, when a trigger skips a row the UPDATE needs" do
    conn.exec(<<~SQL)
      CREATE FUNCTION fx.skip() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN IF NEW.name = 'b' THEN RETURN NULL; END IF; RETURN NEW; END $$;
      CREATE TRIGGER skip BEFORE INSERT ON fx.accounts FOR EACH ROW EXECUTE FUNCTION fx.skip();
    SQL
    round = described_class.compare(runner, prepare(*inserts), original: templates, candidate: templates,
                                                               atoms: [], untested: [])
    expect([round.match, round.rule, round.load_failed]).to eq([nil, :insert_failed, true])
  end

  it "fails the load, disproving nothing, when a trigger moves a row before its UPDATE" do
    conn.exec(<<~SQL)
      CREATE FUNCTION fx.touch() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN UPDATE fx.accounts SET name = name WHERE id = NEW.id; RETURN NULL; END $$;
      CREATE TRIGGER touch AFTER INSERT ON fx.accounts FOR EACH ROW EXECUTE FUNCTION fx.touch();
    SQL
    round = described_class.compare(runner, prepare(*inserts), original: templates, candidate: templates,
                                                               atoms: [], untested: [])
    expect([round.match, round.rule, round.load_failed]).to eq([nil, :insert_failed, true])
  end
end
