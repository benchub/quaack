# frozen_string_literal: true

require "quaack/enclave/store"

# `quaacks anchor --run <run ID>` (README 3h) the way the jump server runs
# it: the installed quaacks in its own process, outside Bundler. It reads the
# run's redacted_query and plan entries and needs no production connection.
RSpec.describe "quaacks anchor" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:query) { "SELECT o.id, now() FROM public.orders o WHERE o.created_at > CURRENT_DATE - $1" }
  let(:search_path) { '"$user", public' }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("redacted_query", query)
      store.write("plan", [{ "Plan" => {}, "Settings" => { "search_path" => search_path } }])
    end
  end

  after { quaacks.remove }

  def no_libpq_env = ENV.keys.grep(/\APG/).to_h { [it, nil] }
  def anchor = quaacks.run("anchor", "--run", store.run_id, env: no_libpq_env)
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

  context "when the plan's search_path puts a schema before pg_catalog" do
    let(:search_path) { "public, pg_catalog" }

    it "refuses with the anchoring rule, storing nothing" do
      outcome = anchor

      expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
        .to eq([%({"type":"error","step":"anchor","rule":"clock_function_search_path"}\n), "", 70])
      expect([stored.entry?("anchored_query"), stored.entry?("clock_replacements")]).to eq([false, false])
    end
  end
end
