# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/structural_discard"
require "quaack/enclave/burndown"

# README step 8's structural discards, against real Postgres.
RSpec.describe Quaack::Enclave::StructuralDiscard do
  let(:conn) { test_database.connection }
  let(:sentinel) { "SENTINEL-step8-9d1e" }
  let(:original) { "SELECT id, name FROM public.t WHERE name = $1" }

  before do
    conn.exec(<<~SQL)
      CREATE TABLE t (id int, name text, n numeric);
      INSERT INTO t SELECT i, 'n' || i, i FROM generate_series(1, 100) AS i;
    SQL
  end

  def check(candidates, literals: [sentinel])
    described_class.check(conn, original:, candidates:, literals:)
  end

  it "keeps candidates that plan and return the same column count and types" do
    kept = ["SELECT t.id, t.name FROM public.t AS t WHERE t.name = $1",
            "SELECT id, name FROM public.t WHERE name = $1 LIMIT 5"]
    result = check(kept)
    expect(result.kept).to eq(kept)
    expect(result.dropped).to eq(failed_to_plan: 0, output_mismatch: 0)
  end

  it "prepares each candidate with the original's parameter types, so one that drops a placeholder still plans" do
    two = "SELECT id, name FROM public.t WHERE name = $1 OR id < $2"
    kept = ["SELECT id, name FROM public.t WHERE name = $1", "SELECT id, name FROM public.t WHERE $2 > id"]

    result = described_class.check(conn, original: two, candidates: kept, literals: [sentinel, "5"])

    expect(result.kept).to eq(kept)
  end

  it "discards a candidate that fails to plan on the racetrack" do
    result = check(["SELECT id, name FROM public.t WHERE name = $1 AND 1 / (id - id) = 1 OR missing = 1",
                    "SELECT id, name FROM public.t WHERE name = $1::int::text AND id = $1::int"])
    expect(result.kept).to eq([])
    expect(result.dropped).to eq(failed_to_plan: 2, output_mismatch: 0)
  end

  it "plans with the literals, so a literal that can't be read fails the plan" do
    result = check(["SELECT id, name FROM public.t WHERE id = $1::int"], literals: ["12"])
    expect(result.kept.size).to eq(1)
    expect(check(["SELECT id, name FROM public.t WHERE id = $1::int"]).dropped[:failed_to_plan]).to eq(1)
  end

  it "discards a candidate whose column count or types differ" do
    result = check(["SELECT id FROM public.t WHERE name = $1",
                    "SELECT id, name, n FROM public.t WHERE name = $1",
                    "SELECT id::bigint, name FROM public.t WHERE name = $1",
                    "SELECT name, id FROM public.t WHERE name = $1"])
    expect(result.kept).to eq([])
    expect(result.dropped).to eq(failed_to_plan: 0, output_mismatch: 4)
  end

  it "leaves no prepared statement or open transaction behind" do
    check(["SELECT id, name FROM public.t WHERE name = $1", "SELECT nope"])
    expect(conn.exec("SELECT count(*) FROM pg_prepared_statements").getvalue(0, 0)).to eq("0")
    expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
  end

  it "keeps literal values out of its result and errors" do
    result = check(["SELECT id, name FROM public.t WHERE name = $1", "SELECT id FROM public.t WHERE name = $1"])
    expect(result.inspect).not_to include(sentinel)
    expect(result.to_h.to_s).not_to include(sentinel)
    # The check itself sees a planted sentinel.
    expect(result.with(kept: [sentinel]).inspect).to include(sentinel)
  end

  it "records the step 8 burndown, inbound-check rejections included" do
    Dir.mktmpdir do |base|
      store = Quaack::Enclave::Store.create(base:)
      result = check(["SELECT id, name FROM public.t WHERE name = $1", "SELECT id FROM public.t WHERE name = $1",
                      "SELECT nope"])
      described_class.record(store, result, inbound_rejected: 3)
      expect(Quaack::Enclave::Burndown.read(store)["stages"]["step8"]["rewrites"]).to eq(
        "in" => 6, "added" => {}, "set_aside" => 0, "out" => 1, "extra" => {},
        "dropped" => { "inbound_check" => 3, "failed_to_plan" => 1, "output_mismatch" => 1 }
      )
    end
  end
end
