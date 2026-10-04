# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/run_server"
require "quaack/enclave/steps/index_search"

# DESIGN.md step 8: the mechanical index search (5a-1 to 5a-4) for one rewrite
# candidate, on its own parse and its plain racetrack plan, run in-process.
RSpec.describe "Steps::IndexSearch.rewrite_entry, against a real server" do
  include_context "an index search run"

  let(:rewrite) do
    "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.status = $2 ORDER BY o.total"
  end

  def rewrite_entry(sql = rewrite)
    with_env(libpq_env) do
      connection = Quaack::Enclave::RunServer.connect(stored, :racetrack)
      Quaack::Enclave::Steps::IndexSearch.rewrite_entry(stored, connection, sql)
    ensure
      connection&.close
    end
  end

  def with_env(env)
    saved = env.keys.to_h { [it, ENV.fetch(it, nil)] }
    env.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  it "runs 5a-1 on the rewrite's parse, 5a-2 on its plain racetrack plan, 5a-3, and 5a-4 with the rewrite" do
    prepare
    entry = rewrite_entry
    candidates = entry["results"].map { Quaack::Enclave::IndexStore.candidate(it["candidate"]) }
    ddls = candidates.map(&:to_ddl)
    # The rewrite's ORDER BY total: 5a-1 on the rewrite's parse and 5a-2 on
    # its plan's Sort both propose an index ending in total. The original has
    # no ORDER BY and its plan no Sort.
    sorted = candidates.find { it.sources.include?(:plan) }
    expect(sorted&.key&.map(&:name)).to eq(%w[note status total])
    expect(sorted.sources.to_a.sort).to eq(%i[parse plan])
    expect(ddls).to include(a_string_matching(/\(note, status\)|\(note\)/))
    expect(candidates.flat_map { it.sources.to_a }.uniq).to include(:parse, :plan)
    # 5a-4 ran the rewrite, not the original: its baseline sorts.
    expect(JSON.generate(entry["baseline"]["slow"]["plan"])).to include("Sort")
    expect(entry["dedupe"]["proposals"].size).to eq(candidates.size)
  end

  it "searches the base table a shared_scan_cte rewrite's MATERIALIZED CTE reads, not the CTE" do
    prepare
    entry = rewrite_entry(
      "WITH quaack_scan_of_orders AS MATERIALIZED (SELECT * FROM public.orders WHERE orders.status = $2) " \
      "SELECT o.note, o.status FROM quaack_scan_of_orders o JOIN quaack_scan_of_orders o2 ON o2.id = o.id " \
      "WHERE o.note = $1"
    )
    candidates = entry["results"].map { Quaack::Enclave::IndexStore.candidate(it["candidate"]) }
    # The CTE's own scan reads public.orders, filtered on status: that's
    # the index that helps, and 5a-1 finds it in the CTE's body. Each copy
    # reads the CTE, which no index can serve, so note, which only the
    # copies filter on, keys nothing.
    expect(candidates.map(&:table).uniq).to eq([orders])
    status = candidates.select { it.key.map(&:name) == %w[status] }
    expect(status.flat_map { it.sources.to_a }).to include(:parse)
    expect(candidates.flat_map { it.key.map(&:name) }).not_to include("note")
  end

  it "stores each plan redacted, with no sentinel literal" do
    prepare
    entry = rewrite_entry
    plans = [*entry["baseline"].values, *entry["results"].flat_map { it["plans"].values }].map { it["plan"] }
    expect(JSON.generate(plans)).to include("$1")
    expect(LeakCheck.findings(sentinels, stdout: JSON.generate(plans))).to eq([])
  end
end
