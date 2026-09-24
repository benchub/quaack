# frozen_string_literal: true

require "quaack/enclave/deparse"

# What the parentheses that Deparse adds (20260924-4) do on real Postgres:
# each query here gives the same rows as its deparse. Most also show what
# pg_query's deparser does on its own, which is to write SQL that gives
# other rows, or an error.
RSpec.describe Quaack::Enclave::Deparse do
  let(:conn) { test_database.connection }

  # Every mix of true, false, and NULL, with a number and a timestamp.
  before do
    conn.exec(<<~SQL)
      CREATE TEMP TABLE mix AS
      SELECT row_number() OVER () AS id, a, b, c, d, n, created_at
      FROM (VALUES (true), (false), (NULL)) a (a), (VALUES (true), (false), (NULL)) b (b),
        (VALUES (true), (false), (NULL)) c (c), (VALUES (true), (false), (NULL)) d (d),
        (VALUES (0), (1), (NULL)) n (n), (VALUES (timestamp '2026-03-01 12:00'), (NULL)) t (created_at)
    SQL
  end

  def rows(sql) = conn.exec(sql).values

  def faithful(sql) = described_class.faithfully(PgQuery.parse(sql).tree)

  def raw(sql) = PgQuery.deparse(PgQuery.parse(sql).tree)

  # What the deparser's own SQL gives: other rows, an error, or the same
  # rows when the tree it parses to happens to mean the same thing.
  def raw_outcome(sql)
    rows(raw(sql)) == rows(sql) ? :same : :other_rows
  rescue PG::Error
    :error
  end

  {
    "(a OR b) IS NULL" => :other_rows,
    "(a AND b) IS NOT NULL" => :other_rows,
    "(NOT a) IS NULL" => :other_rows,
    "(a AND b) IN (true)" => :same,
    "(a AND b) = ANY(ARRAY[c])" => :other_rows,
    "(n = 1) = ANY(ARRAY[true])" => :error,
    "a IS NOT DISTINCT FROM (b AND c)" => :other_rows,
    "a BETWEEN (b AND c) AND d" => :other_rows,
    # The deparser's SQL appends '' to the time as text, which in UTC
    # happens to print the same.
    "created_at AT TIME ZONE ('UTC' || '')" => :same,
    "created_at AT TIME ZONE ('America/' || 'New_York')" => :error,
    "(a IS DISTINCT FROM b) IS NOT TRUE" => :error,
    "(a IS NOT DISTINCT FROM b) IS NOT FALSE" => :error,
    "a BETWEEN b AND (c OR d)" => :other_rows,
    "c = (a = ANY(SELECT m.b FROM mix m WHERE m.id = mix.id))" => :error,
    "(n = 1) NOT IN (SELECT m.a FROM mix m WHERE m.id = 1)" => :error,
    "(ARRAY(SELECT mix.a))[1]" => :error
  }.each do |expression, outcome|
    it "gives the same rows for #{expression}" do
      sql = "SELECT id, #{expression} FROM mix ORDER BY id"
      original = rows(sql)
      expect(original.size).to eq(486)
      expect(original.map(&:last).uniq.size).to be > 1
      expect(rows(faithful(sql))).to eq(original)
      expect(raw_outcome(sql)).to eq(outcome)
    end
  end
end
