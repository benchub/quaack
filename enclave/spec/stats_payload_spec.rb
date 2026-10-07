# frozen_string_literal: true

require "quaack/enclave/stats_payload"

# The stats the llm-index-ideas and llm-rewrites payloads send (DESIGN.md's llm-index-ideas): classify's
# outbound statistics, keeping only the columns the query references.
RSpec.describe Quaack::Enclave::StatsPayload do
  def column(name)
    { "name" => name, "n_distinct" => 3, "null_frac" => 0.0, "correlation" => nil,
      "most_common_freqs" => [0.5], "most_common_vals" => ["#{name}-value"] }
  end

  def table(name, *columns)
    { "schema" => "public", "name" => name, "columns" => columns.map { column(it) },
      "indexes" => [{ "name" => "#{name}_pkey", "definition" => "CREATE INDEX ...", "columns" => {} }],
      "extended_statistics" => [] }
  end

  let(:outbound) do
    { "tables" => [table("orders", "id", "customer_id", "status", "note", "created_at"),
                   table("customers", "id", "name", "email", "region")] }
  end

  def kept(*sqls)
    described_class.subset(outbound, sqls)["tables"].to_h { [it["name"], it["columns"].map { |c| c["name"] }] }
  end

  it "keeps only the columns the query references, wherever it references them" do
    sql = "SELECT o.status, count(*) FROM public.orders o JOIN public.customers c ON c.id = o.customer_id " \
          "WHERE o.created_at > $1 GROUP BY o.status HAVING max(c.region) = 'x' ORDER BY o.status"

    expect(kept(sql)).to eq("orders" => %w[customer_id status created_at], "customers" => %w[id region])
  end

  it "keeps each kept column's stats and each table's other fields exactly as classify stored them" do
    trimmed = described_class.subset(outbound, ["SELECT o.note FROM public.orders o"])

    expect(trimmed["tables"].first).to eq(outbound["tables"].first.merge("columns" => [column("note")]))
    expect(trimmed["tables"].last).to eq(outbound["tables"].last.merge("columns" => []))
  end

  it "finds columns in subqueries, CTEs, window clauses, and USING" do
    sql = "WITH recent AS (SELECT o.customer_id FROM public.orders o WHERE o.created_at > now()) " \
          "SELECT row_number() OVER (PARTITION BY c.region ORDER BY c.id) FROM public.customers c " \
          "JOIN recent USING (customer_id) WHERE EXISTS (SELECT 1 FROM public.orders o2 WHERE o2.status = 'x')"

    expect(kept(sql)).to eq("orders" => %w[customer_id status created_at], "customers" => %w[id region])
  end

  it "keeps a USING column for every table that has it" do
    expect(kept("SELECT 1 FROM public.orders JOIN public.customers USING (id)"))
      .to eq("orders" => %w[id], "customers" => %w[id])
  end

  it "resolves a qualifier by alias, table name, or schema and table name" do
    sql = "SELECT public.orders.note, orders.status FROM public.orders JOIN public.customers cu ON cu.email = 'x'"

    expect(kept(sql)).to eq("orders" => %w[status note], "customers" => %w[email])
  end

  it "tells apart same-named tables in different schemas by a schema-qualified reference" do
    outbound["tables"] << table("orders", "id", "note").merge("schema" => "archive")
    trimmed = described_class.subset(outbound, ["SELECT archive.orders.note FROM archive.orders, public.orders"])

    expect(trimmed["tables"].map { [it["schema"], it["columns"].map { |c| c["name"] }] })
      .to eq([["public", []], ["public", []], ["archive", %w[note]]])
  end

  it "keeps an unqualified or unresolvable column for every table that has it" do
    sql = "SELECT name, sub.status FROM public.orders o JOIN public.customers c ON true " \
          "JOIN (SELECT 1) sub ON id = 1"

    expect(kept(sql)).to eq("orders" => %w[id status], "customers" => %w[id name])
  end

  it "keeps every column of a table a star or whole-row reference covers" do
    expect(kept("SELECT c.*, o.id FROM public.orders o, public.customers c"))
      .to eq("orders" => %w[id], "customers" => %w[id name email region])
    expect(kept("SELECT c FROM public.orders o, public.customers c"))
      .to eq("orders" => [], "customers" => %w[id name email region])
    expect(kept("SELECT * FROM public.orders o, public.customers c WHERE o.id = 1"))
      .to eq("orders" => %w[id customer_id status note created_at], "customers" => %w[id name email region])
    expect(kept("SELECT 1 FROM public.orders NATURAL JOIN public.customers"))
      .to eq("orders" => %w[id customer_id status note created_at], "customers" => %w[id name email region])
  end

  it "keeps a column any of several queries references" do
    expect(kept("SELECT o.note FROM public.orders o", "SELECT o.status FROM public.orders o WHERE o.id = $1"))
      .to eq("orders" => %w[id status note], "customers" => [])
  end

  it "keeps everything when a query won't parse" do
    expect(kept("SELECT o.note FROM public.orders o", "SELEC nonsense"))
      .to eq("orders" => %w[id customer_id status note created_at], "customers" => %w[id name email region])
  end
end
