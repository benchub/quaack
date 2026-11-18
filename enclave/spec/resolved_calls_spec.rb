# frozen_string_literal: true

require "quaack/enclave/insert_values"
require "quaack/enclave/resolved_calls"

# Task 20261114-170743-1: Postgres resolves the values' calls on a shell
# of them, so no type input function or typmodin runs on an LLM's values
# before the volatility check.
RSpec.describe Quaack::Enclave::ResolvedCalls do
  let(:sentinel) { "SENTINEL_7f3a" }

  def probe(values)
    rows = [PgQuery.parse("INSERT INTO t VALUES (#{values})").tree.stmts.first.stmt.insert_stmt
                   .select_stmt.select_stmt.values_lists.first.list.items.to_a]
    Quaack::Enclave::InsertValues.probe(rows)
  end

  it "sends no string or bit-string constant and no type modifier to Postgres" do
    sql = described_class.shell_sql(probe("lower('#{sentinel}'::varchar(77)), B'101', " \
                                          "ARRAY['#{sentinel}'], timezone('#{sentinel}', '#{sentinel}'::timestamp)"))

    expect(sql).not_to include(sentinel)
    expect(sql).not_to include("77")
    expect(sql).not_to include("101")
    expect(sql).to include("lower(NULL::varchar)").and include("timezone(NULL, NULL::timestamp)")
  end

  it "keeps numbers and booleans, which the parser types itself" do
    expect(described_class.shell_sql(probe("abs(5000000000), round(1.5), true")))
      .to eq("SELECT abs(5000000000) AS c1, round(1.5) AS c2, true AS c3")
  end

  it "falls back to nil, leaving the connection as it was, in a read-only transaction" do
    conn = test_database.connection
    conn.exec("BEGIN READ ONLY")
    expect(described_class.of(probe("timezone('UTC', '2024-01-01'::timestamp)"), ["pg_catalog"], conn)).to be_nil
    expect(conn.exec("SELECT 1").getvalue(0, 0)).to eq("1")
    conn.exec("ROLLBACK")
  end

  it "lists the non-immutable function a call resolves to" do
    conn = test_database.connection
    functions = described_class.of(probe("timezone('UTC', '12:00+00'::timetz)"), ["pg_catalog"], conn)
    expect(functions.map { [it.schema, it.name, it.volatility] }).to eq([%w[pg_catalog timezone stable]])
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  # Task 20261118-223225-1: casts Postgres adds (funcformat 1 and 2) are
  # left to the volatility check.
  it "leaves out the casts Postgres adds, explicit or implicit" do
    conn = test_database.connection
    functions = described_class.of(probe("to_char('2024-01-01'::date, 'YYYY'), '2024-01-01'::date::timestamptz"),
                                   ["pg_catalog"], conn)
    expect(functions.map { [it.schema, it.name] }).to eq([%w[pg_catalog to_char]])
  end
end
