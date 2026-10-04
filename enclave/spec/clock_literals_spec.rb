# frozen_string_literal: true

require "quaack/enclave/clock_anchoring"

# clock-anchor for the clock-reading literals 'now', 'today', 'yesterday', and
# 'tomorrow' (task 20260926-48). By the time clock-anchor runs, redact has made each
# literal a placeholder, so anchoring reads the words from the placeholder
# map, and the implicit types from statistics's clock_columns.
# clock_anchoring_postgres_spec.rb checks the values on real Postgres.
RSpec.describe Quaack::Enclave::ClockAnchoring do
  let(:statistics) do
    { "tables" => [{ "schema" => "public", "name" => "orders", "column_names" => %w[id status created_at],
                     "clock_columns" => { "created_at" => "timestamptz" } }] }
  end

  def map(*values) = values.each_with_index.to_h { |v, i| ["$#{i + 1}", { "value" => v, "type" => "unknown" }] }

  def anchor(sql, placeholder_map) = described_class.anchor(sql, nil, placeholder_map:, statistics:)

  def deparse(sql) = PgQuery.parse(sql).deparse

  def restore(result) = described_class.restore(result.sql, result.replacements, result.added_names)

  anchor = "quaack.clock_anchor()"
  today = "#{anchor}::pg_catalog.date"

  describe "a literal cast to a date or timestamp" do
    {
      %w[now date] => "(#{anchor})::date",
      %w[today date] => "(#{today})::date",
      %w[yesterday date] => "(#{today} - 1)::date",
      %w[tomorrow date] => "(#{today} + 1)::date",
      %w[now timestamp] => "(#{anchor})::timestamp",
      ["today", "timestamp(0)"] => "(#{today})::timestamp(0)",
      %w[yesterday timestamptz] => "(#{today} - 1)::timestamptz",
      ["tomorrow", "timestamp with time zone"] => "(#{today} + 1)::pg_catalog.timestamptz",
      %w[now time] => "(#{anchor})::time"
    }.each do |(word, type), anchored|
      it "turns '#{word}'::#{type} into #{anchored}" do
        result = anchor("SELECT $1::#{type} AS x FROM public.orders", map(word))
        expect(result.sql).to eq(deparse("SELECT #{anchored} AS x FROM public.orders"))
        expect(restore(result)).to eq(deparse("SELECT $1::#{type} AS x FROM public.orders"))
      end
    end

    it "reads the word as Postgres does, in any case and with spaces around it" do
      result = anchor("SELECT $1::date, $2::date", map(" ToDay ", "\tNOW\n"))
      expect(result.sql).to eq(deparse("SELECT (#{today})::date AS date, " \
                                       "(#{anchor})::date AS date"))
    end

    it "records the placeholder it replaced, which is shape" do
      result = anchor("SELECT $1::date AS x", map("yesterday"))
      expect(result.replacements)
        .to eq([described_class::Replacement.new(original: "$1::date",
                                                 anchored: "(#{today} - 1)::date")])
    end
  end

  describe "restore with an unrelated $n::date next to an anchored one" do
    let(:sql) { "SELECT $1::date AS a, $2::date AS b FROM public.orders" }
    let(:result) { anchor(sql, map("2020-01-01", "today")) }

    it "leaves the unrelated cast alone and puts the anchored one back" do
      expect(result.sql).to eq(deparse("SELECT $1::date AS a, (#{today})::date AS b FROM public.orders"))
      expect(restore(result)).to eq(deparse(sql))
    end

    it "refuses when the anchored cast is gone, even though an unrelated $n::date is there" do
      expect { described_class.restore(deparse(sql), result.replacements, result.added_names) }
        .to raise_error(described_class::Error,
                        "restore_mismatch: the SQL has fewer clock anchors than the replacements")
    end
  end

  describe "a literal compared with a date or timestamp column" do
    it "casts the anchor to the column's type, and restore puts the placeholder back" do
      sql = "SELECT o.id FROM public.orders o WHERE o.created_at >= $1 AND o.created_at < $2 AND o.status = $3"
      result = anchor(sql, map("yesterday", "Today", "open"))
      expect(result.sql).to eq(deparse(
                                 "SELECT o.id FROM public.orders o WHERE o.created_at >= (#{today} - 1)::" \
                                 "pg_catalog.timestamptz AND o.created_at < (#{today})::pg_catalog.timestamptz " \
                                 "AND o.status = $3"
                               ))
      expect(restore(result)).to eq(deparse(sql))
    end

    it "anchors BETWEEN and IN too" do
      sql = "SELECT id FROM public.orders WHERE created_at BETWEEN $1 AND $2 OR created_at IN ($3)"
      result = anchor(sql, map("yesterday", "now", "tomorrow"))
      expect(result.replacements.map(&:original)).to eq(%w[$1 $2 $3])
    end
  end

  describe "what it leaves alone" do
    [
      ["a real date", "SELECT $1::date, $1::timestamptz FROM public.orders WHERE created_at > $1", "2024-01-01"],
      ["a word compared with a text column", "SELECT id FROM public.orders WHERE status = $1", "today"],
      ["a word cast to text", "SELECT $1::text", "today"],
      ["a word that isn't a clock word", "SELECT $1::date WHERE $1::timestamp < now()", "epoch"],
      ["today as a time, which isn't a clock reading", "SELECT $1::time", "today"],
      ["a word inside a longer string", "SELECT $1::timestamp", "today 12:00"]
    ].each do |what, sql, value|
      it "leaves #{what}" do
        result = anchor(sql, map(value))
        expect(result.replacements.map(&:original)).to eq(sql.include?("now()") ? ["now()"] : [])
      end
    end

    it "leaves a clock word whose placeholder isn't an untyped string" do
      result = anchor("SELECT $1::date", { "$1" => { "value" => "today", "type" => "integer" } })
      expect(result.replacements).to eq([])
    end
  end
end
