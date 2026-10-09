# frozen_string_literal: true

require "pg_query"
require "quaack/enclave/arena_runner"
require "quaack/enclave/scenarios"
require "quaack/enclave/scenario_tests"

# rewrite-test on an acyclic schema with a nullable foreign key. The
# LEFT JOIN anti-join that ORMs produce, and IS NULL on the nullable key,
# must build fixtures that load, not refuse with fixture_load_failed.
RSpec.describe Quaack::Enclave::ScenarioTests do
  let(:conn) { racetrack_and_arena.arena.connection }

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA fx;
      CREATE TABLE fx.accounts (id integer PRIMARY KEY, name text NOT NULL);
      CREATE TABLE fx.terms (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts);
      CREATE TABLE fx.templates (id integer PRIMARY KEY, label text NOT NULL);
      CREATE TABLE fx.courses (id integer PRIMARY KEY, account_id integer NOT NULL REFERENCES fx.accounts,
        template_id integer REFERENCES fx.templates);
    SQL
  end

  def verdicts(sql, candidates)
    report = described_class.run(conn, sql, candidates)
    expect(report.refused).to be_nil
    expect(report.results.map(&:rule)).not_to include(:fixture_load_failed)
    report.results.map { |r| [r.passed, r.rule] }
  end

  it "loads IS NULL on a nullable foreign key, passing an equivalent rewrite and disproving a wrong one" do
    expect(verdicts("SELECT c.id FROM fx.courses c WHERE c.template_id IS NULL ORDER BY c.id",
                    ["SELECT c.id FROM fx.courses c WHERE NOT EXISTS (SELECT 1 FROM fx.templates t WHERE t.id = c.template_id) ORDER BY c.id",
                     "SELECT c.id FROM fx.courses c ORDER BY c.id"]))
      .to eq([[true, nil], [false, :row_count]])
  end

  # A group with no template skips; the terms row under accounts must not orphan.
  it "loads a LEFT JOIN anti-join whose group skips, beside a third table under the parent" do
    sql = "SELECT c.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id " \
          "LEFT JOIN fx.templates t ON t.id = c.template_id WHERE t.id IS NULL ORDER BY c.id"
    expect(verdicts(sql,
                    ["SELECT c.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id " \
                     "WHERE NOT EXISTS (SELECT 1 FROM fx.templates t WHERE t.id = c.template_id) ORDER BY c.id",
                     "SELECT c.id FROM fx.courses c JOIN fx.accounts a ON a.id = c.account_id ORDER BY c.id"]))
      .to eq([[true, nil], [false, :row_count]])
  end

  it "loads an anti-join on the nullable edge itself" do
    sql = "SELECT a.id FROM fx.accounts a LEFT JOIN fx.courses c ON c.account_id = a.id " \
          "LEFT JOIN fx.templates t ON t.id = c.template_id WHERE t.id IS NULL ORDER BY a.id"
    expect(verdicts(sql,
                    ["SELECT a.id FROM fx.accounts a LEFT JOIN fx.courses c ON c.account_id = a.id " \
                     "WHERE c.template_id IS NULL ORDER BY a.id",
                     "SELECT a.id FROM fx.accounts a ORDER BY a.id"]))
      .to eq([[true, nil], [false, :row_count]])
  end
end
