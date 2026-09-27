# frozen_string_literal: true

require "quaack/enclave/implicit_name"

# Postgres is the oracle: each expression's column name, as Postgres names
# it, must be the one ImplicitName works out from the parse.
RSpec.describe Quaack::Enclave::ImplicitName do
  let(:conn) { test_database.connection }

  def from = "FROM (SELECT 1 AS a, ARRAY[1] AS arr, 'x'::text AS s) t"

  [
    "a", "t.a", "now()", "pg_catalog.now()", "extract(year FROM now())", "1", "1 + 1", "-a", "(a)", "NOT true",
    "a IS NULL", "nullif(1, 2)", "a::text", "(a + 1)::text", "now()::date", "(1 + 1)::pg_catalog.int8",
    "s COLLATE \"C\"", "(s || 'y') COLLATE \"C\"", "CASE WHEN true THEN 1 END", "CASE WHEN true THEN 1 ELSE a END",
    "CASE WHEN true THEN 1 ELSE 2 END", "CASE WHEN true THEN 1 ELSE 2::int8 END", "CASE a WHEN 1 THEN now() END",
    "(SELECT a)", "(SELECT 1)", "(SELECT 1 AS z)", "(SELECT a UNION SELECT 1 AS q)", "(SELECT 1 UNION SELECT a)",
    "(SELECT (SELECT a))", "EXISTS (SELECT 1)", "ARRAY(SELECT 1)", "a IN (SELECT 1)", "a IN (SELECT a)",
    "ARRAY[1]", "arr[1]",
    "coalesce(a, 1)", "greatest(a, 1)", "least(1, 2)", "CURRENT_DATE", "CURRENT_TIME", "current_time(1)",
    "CURRENT_TIMESTAMP", "current_timestamp(2)", "LOCALTIME", "localtime(2)", "LOCALTIMESTAMP",
    "localtimestamp(3)", "CURRENT_USER", "SESSION_USER", "USER", "CURRENT_ROLE", "CURRENT_CATALOG",
    "CURRENT_SCHEMA", "(1 + 1)::int8::text", "CASE WHEN true THEN 1 END::text", "(VALUES (1))", "(SELECT 1)::text"
  ].each do |expression|
    it "names #{expression} the way Postgres does" do
      sql = "SELECT #{expression} #{from}"
      val = PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt.target_list.first.res_target.val
      expect(described_class.of(val)).to eq(conn.exec(sql).fields.first)
    end
  end
end
