# frozen_string_literal: true

require "quaack/enclave/scenario_tests"

# rewrite-test on the prompt pack's schema (users, products, orders, line_items):
# unique indexes made with CREATE UNIQUE INDEX, identity keys, and foreign
# keys to tables the query doesn't name. Every fixture must load, so a
# candidate identical to the original passes.
RSpec.describe Quaack::Enclave::ScenarioTests do
  let(:conn) { racetrack_and_arena.arena.connection }

  # arena already has public tables, so the schema goes into its own.
  before do
    sql = File.read(File.join(__dir__, "fixtures", "prompt_pack_schema.sql"))
    conn.exec("CREATE SCHEMA shop; #{sql.gsub("public.", "shop.")}")
  end

  def passes_itself(sql)
    report = begin
      described_class.run(conn, sql, [sql])
    rescue Quaack::Enclave::ArenaRunner::Error => e
      raise "fixture failed to load: #{e.sqlstate}"
    end
    expect(report.results.map { |r| [r.passed, r.rule] }).to eq([[true, nil]])
  end

  it "loads an ORM-style join whose parent (users) the query doesn't name" do
    passes_itself(<<~SQL)
      SELECT "orders"."id", "orders"."status", "line_items"."quantity" FROM "shop"."orders"
      INNER JOIN "shop"."line_items" ON "line_items"."order_id" = "orders"."id"
      WHERE "orders"."status" = 'shipped' LIMIT 50
    SQL
  end

  it "tests a keyset page on orders, passing the expanded form and disproving one that drops the keyset" do
    page = "SELECT o.id FROM shop.orders o WHERE o.status = 'shipped' AND (o.created_at, o.id) < " \
           "('2026-09-01 00:00:00+00', 900) ORDER BY o.created_at DESC, o.id DESC LIMIT 20"
    expanded = "SELECT o.id FROM shop.orders o WHERE o.status = 'shipped' AND (o.created_at < " \
               "'2026-09-01 00:00:00+00' OR (o.created_at = '2026-09-01 00:00:00+00' AND o.id < 900)) " \
               "ORDER BY o.created_at DESC, o.id DESC LIMIT 20"
    dropped = "SELECT o.id FROM shop.orders o WHERE o.status = 'shipped' ORDER BY o.created_at DESC, o.id DESC LIMIT 20"
    report = described_class.run(conn, page, [expanded, dropped])
    expect(report.untested).to eq([])
    expect(report.results.map { [it.passed, it.scenario] }).to eq([[true, nil], [false, :s1]])
  end

  it "disproves a keyset page on orders whose candidate changes only the tie-breaker (identity id)" do
    page = "SELECT o.id FROM shop.orders o WHERE o.status = 'shipped' AND (o.created_at, o.id) < " \
           "('2026-09-01 00:00:00+00', 900) ORDER BY o.created_at DESC, o.id DESC LIMIT 20"
    report = described_class.run(conn, page, [page, page.sub("900)", "901)")])
    expect(report.untested).to eq([])
    expect(report.results.map(&:passed)).to eq([true, false])
  end

  it "disproves a tie-breaker change when the keyset id is 1, below the ids the database generates" do
    page = "SELECT o.id FROM shop.orders o WHERE o.status = 'shipped' AND (o.created_at, o.id) < " \
           "('2026-09-01 00:00:00+00', 1) ORDER BY o.created_at DESC, o.id DESC LIMIT 20"
    report = described_class.run(conn, page, [page, page.sub(" 1)", " 2)")])
    expect(report.untested).to eq([])
    expect(report.results.map(&:passed)).to eq([true, false])
  end

  it "loads a GROUP BY over a table with a unique index" do
    passes_itself(<<~SQL)
      SELECT u.country, count(*) FROM shop.users u WHERE u.status = 'active' GROUP BY u.country
    SQL
  end
end
