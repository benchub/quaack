# frozen_string_literal: true

require "quaack/enclave/arena_runner"
require "quaack/enclave/result_comparison"
require "quaack/enclave/table_name"

# A fixture row's deferred columns, for a foreign-key cycle step 9 cuts:
# the row loads with NULL there, and once every row has loaded, an UPDATE
# keyed to its tableoid and ctid sets the row's own values.
RSpec.describe Quaack::Enclave::ArenaRunner do
  let(:conn) { racetrack_and_arena.arena.connection }
  let(:runner) { described_class.new(conn) }
  let(:sentinel) { "987654321" }

  let(:accounts) { Quaack::Enclave::TableName.new(schema: "fx", name: "accounts") }
  let(:courses) { Quaack::Enclave::TableName.new(schema: "fx", name: "courses") }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.accounts (id integer PRIMARY KEY, course_template_id integer);
      CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts);
      ALTER TABLE fx.accounts ADD FOREIGN KEY (course_template_id) REFERENCES fx.courses;
    SQL
  end

  def account(id, template)
    described_class::FixtureRow.new(table: accounts, columns: %w[id course_template_id],
                                    values: [id.to_s, template&.to_s], deferred: ["course_template_id"])
  end

  def course(id, account)
    described_class::FixtureRow.new(table: courses, columns: %w[id account_id],
                                    values: [id.to_s, account.to_s])
  end

  let(:rows) { [account(1, 10), account(2, nil), account(3, 20), course(10, 1), course(20, 3)] }

  # A seq scan, so the rows come back in heap order.
  def loaded(rows)
    runner.with_fixture(rows, index_scans: false) do |tx|
      tx.query("SELECT id, course_template_id FROM fx.accounts").rows
    end
  end

  def load_error(rows)
    runner.with_fixture(rows) { nil }
    raise "expected ArenaRunner::Error"
  rescue described_class::Error => e
    e
  end

  it "loads a cycle's rows with the deferred values set, keeping the load order in the heap, both ways round" do
    expect(loaded(rows)).to eq([%w[1 10], ["2", nil], %w[3 20]])
    expect(loaded(Quaack::Enclave::ResultComparison.reverse_load(rows))).to eq([%w[3 20], ["2", nil], %w[1 10]])
  end

  it "fails the load with fixture_load_failed, naming no value, when a deferred value breaks a constraint" do
    error = load_error([account(1, sentinel), course(10, 1)])

    expect([error.rule, error.step, error.index, error.cause]).to eq([:fixture_load_failed, :load, 0, nil])
    expect([error.message, error.inspect, error.full_message]).to all(satisfy { |text| !text.include?(sentinel) })
    # Postgres's own error names the value, so the check above can catch it.
    expect { conn.exec("INSERT INTO fx.accounts VALUES (1, #{sentinel})") }.to raise_error(PG::Error, /#{sentinel}/)
  end

  it "fails the load when a row isn't found again for its UPDATE" do
    conn.exec(<<~SQL)
      CREATE FUNCTION fx.skip() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NULL; END $$;
      CREATE TRIGGER skip BEFORE UPDATE ON fx.accounts FOR EACH ROW EXECUTE FUNCTION fx.skip();
    SQL

    error = load_error([account(5, nil), account(1, nil)])

    expect([error.rule, error.step, error.index]).to eq([:fixture_load_failed, :load, 0])
  end

  it "refuses deferred columns that aren't among the row's columns, without naming a value" do
    [nil, ["note"], [:id], "id"].each do |deferred|
      expect do
        described_class::FixtureRow.new(table: accounts, columns: ["id"], values: [sentinel], deferred:)
      end.to raise_error(ArgumentError, "a fixture row's deferred columns must be among its columns"), deferred.inspect
    end
  end

  it "defers nothing by default" do
    expect(described_class::FixtureRow.new(table: accounts, columns: ["id"], values: ["1"]).deferred).to eq([])
  end
end
