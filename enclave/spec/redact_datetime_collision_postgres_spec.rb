# frozen_string_literal: true

require "json"
require "quaack/enclave/store"
require_relative "support/production_server"

# 20261110-10: a date literal's printed form can equal another literal's text,
# as '2026-01-01' printed as a timestamp equals '2026-01-01 00:00:00', and '5'
# printed as an interval equals '00:00:05'. Such a text in the plan is either
# literal, so it's masked, never given the wrong $n.
RSpec.describe "quaacks redact, with a printed date that equals another literal" do
  let(:events) { <<~SQL }
    CREATE TABLE public.events (id int, created_at timestamp, wait interval, note text);
    INSERT INTO public.events SELECT g, '2025-12-01'::timestamp + g * interval '1 day',
      g * interval '1 second', 'n' || g FROM generate_series(1, 100) g;
  SQL
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("qualified_query", query)
      store.write("plan", explain)
    end
  end

  after do
    quaacks.remove
    production.drop
  end

  def explain
    conn = production.connect
    conn.exec(events)
    JSON.parse(conn.exec("EXPLAIN (ANALYZE, FORMAT JSON) #{query}").getvalue(0, 0))
  ensure
    conn&.close
  end

  def redact = quaacks.run("redact", "--run", store.run_id, env: production.quaacks_env(quaacks.home))
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def filter
    outcome = redact
    expect([outcome.stdout, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), 0])
    stored.read("redacted_plan").dig("explain", 0, "Plan", "Filter")
  end

  context "when a date prints as another literal's timestamp text" do
    let(:query) do
      "SELECT e.id FROM public.events e WHERE e.created_at >= '2026-01-01' AND e.note <> '2026-01-01 00:00:00'"
    end

    it "masks the shared text rather than give either literal the other's $n" do
      expect(store.read("plan").dig(0, "Plan", "Filter").scan("'2026-01-01 00:00:00'").size).to eq(2)

      expect(filter).to eq("((created_at >= $?::timestamp without time zone) AND (note <> $?::text))")
    end
  end

  context "when a number prints as another literal's interval text" do
    let(:query) { "SELECT e.id FROM public.events e WHERE e.wait > '5' AND e.note <> '00:00:05'" }

    it "masks the shared text rather than give either literal the other's $n" do
      expect(store.read("plan").dig(0, "Plan", "Filter").scan("'00:00:05'").size).to eq(2)

      expect(filter).to eq("((wait > $?::interval) AND (note <> $?::text))")
    end
  end

  # 20261112-150000-1: '10' and 10.0 are different values with the same
  # number, so a 10 in the plan could be either, and it's masked.
  context "when a string and a number literal give the same number" do
    let(:query) { "SELECT e.id FROM public.events e WHERE e.id::numeric > '10' AND e.id::numeric < 10.0" }

    it "masks both rather than swap their $n" do
      expect(filter).to eq("(((id)::numeric > $?::numeric) AND ((id)::numeric < $?))")
    end
  end

  context "when the same number is used twice" do
    let(:query) { "SELECT e.id FROM public.events e WHERE e.id > 10 AND e.id <> 10" }

    it "still gives each its $n" do
      expect(filter).to match(/\A\(\(id > \$\d\) AND \(id <> \$\d\)\)\z/)
    end
  end
end
