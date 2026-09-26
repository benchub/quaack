# frozen_string_literal: true

require "quaack/enclave/step_nine"

# Step 9 on the prompt pack's schema (users, products, orders, line_items):
# unique indexes made with CREATE UNIQUE INDEX, identity keys, and foreign
# keys to tables the query doesn't name. Every fixture must load, so a
# candidate identical to the original passes.
RSpec.describe Quaack::Enclave::StepNine do
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

  it "loads a GROUP BY over a table with a unique index" do
    passes_itself(<<~SQL)
      SELECT u.country, count(*) FROM shop.users u WHERE u.status = 'active' GROUP BY u.country
    SQL
  end
end
