# frozen_string_literal: true

require "quaack/enclave/store"

# `quaacks anchor --run <run ID>` (DESIGN.md 3h) the way the jump server runs
# it: the installed quaacks in its own process, outside Bundler. It reads the
# run's redacted_query and plan entries and needs no production connection.
RSpec.describe "quaacks anchor" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:query) { "SELECT o.id, now() FROM public.orders o WHERE o.created_at > CURRENT_DATE - $1" }
  let(:search_path) { '"$user", public' }
  let(:placeholder_map) { { "$1" => { "value" => "7", "type" => "integer" } } }
  let(:statistics) do
    { "tables" => [{ "schema" => "public", "name" => "orders", "column_names" => %w[id created_at],
                     "clock_columns" => { "created_at" => "timestamptz" } }] }
  end
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("redacted_query", query)
      store.write("plan", [{ "Plan" => {}, "Settings" => { "search_path" => search_path } }])
      store.write("placeholder_map", placeholder_map)
      store.write("statistics", statistics)
    end
  end

  after { quaacks.remove }

  def no_libpq_env = ENV.keys.grep(/\APG/).to_h { [it, nil] }
  def anchor = quaacks.run("clock-anchor", "--run", store.run_id, env: no_libpq_env)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  it "stores the anchored query and what it replaced, printing only DONE" do
    outcome = anchor

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(stored.read("anchored_query")).to eq(
      "SELECT o.id, quaack.clock_anchor() AS now FROM public.orders o " \
      "WHERE o.created_at > (quaack.clock_anchor()::pg_catalog.date - $1)"
    )
    expect(stored.read("clock_replacements")).to eq(
      "replacements" => [{ "original" => "now()", "anchored" => "quaack.clock_anchor()" },
                         { "original" => "current_date", "anchored" => "quaack.clock_anchor()::pg_catalog.date" }],
      "added_names" => [{ "slot" => 1, "name" => "now" }]
    )
  end

  context "when the query compares a column with a clock-reading literal" do
    let(:query) { "SELECT o.id FROM public.orders o WHERE o.created_at >= $1 AND o.id = $2" }
    let(:placeholder_map) do
      { "$1" => { "value" => "yesterday", "type" => "unknown" }, "$2" => { "value" => "7", "type" => "integer" } }
    end

    it "anchors it from the placeholder map and the column's type, recording only the placeholder" do
      expect(anchor.status.exitstatus).to eq(0)
      expect(stored.read("anchored_query")).to eq(
        "SELECT o.id FROM public.orders o WHERE o.created_at >= " \
        "(quaack.clock_anchor()::pg_catalog.date - 1)::timestamp with time zone AND o.id = $2"
      )
      expect(stored.read("clock_replacements")["replacements"]).to eq(
        [{ "original" => "$1", "anchored" => "(quaack.clock_anchor()::pg_catalog.date - 1)::timestamp with time zone" }]
      )
      expect(stored.read("clock_replacements").to_s).not_to include("yesterday")
    end
  end

  context "with now() minus an interval placeholder" do
    let(:query) { "SELECT o.id FROM public.orders o WHERE o.created_at > now() - interval $1" }
    let(:placeholder_map) { { "$1" => { "value" => "7 days", "type" => "interval" } } }

    it "anchors now() and keeps the placeholder" do
      expect(anchor.status.exitstatus).to eq(0)
      expect(stored.read("anchored_query"))
        .to eq("SELECT o.id FROM public.orders o WHERE o.created_at > (quaack.clock_anchor() - $1::interval)")
      expect(stored.read("clock_replacements")["replacements"])
        .to eq([{ "original" => "now()", "anchored" => "quaack.clock_anchor()" }])
    end
  end

  context "when the plan's search_path puts a schema before pg_catalog" do
    let(:search_path) { "public, pg_catalog" }

    it "refuses with the anchoring rule, storing nothing" do
      outcome = anchor

      expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
        .to eq([%({"type":"error","step":"clock-anchor","rule":"clock_function_search_path"}\n), "", 70])
      expect([stored.entry?("anchored_query"), stored.entry?("clock_replacements")]).to eq([false, false])
    end
  end
end
