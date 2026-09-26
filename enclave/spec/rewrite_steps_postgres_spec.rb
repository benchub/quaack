# frozen_string_literal: true

require "quaack/enclave/steps/index_payload"
require_relative "support/index_search_run"

# `quaacks rewrite-payload` and `quaacks rewrite-check` (README 6a and 6b,
# with step 8's structural discards), the way the jump server runs them.
RSpec.describe "quaacks rewrite-payload and rewrite-check, against a real server" do
  include_context "an index search run"

  let(:schema_subset) { { "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);" } }
  let(:same) { "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1" }

  def ready
    prepare
    store.write("schema_subset", schema_subset)
  end

  def rewrite_check(stdin) = quaacks.run("rewrite-check", "--run", store.run_id, stdin:, env: libpq_env)
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }

  def rewrite(sql, assumptions = [])
    { "sql" => sql, "transformation" => "t #{sentinels.text}", "assumptions" => assumptions }
  end

  def rewrites(*list, **extra) = JSON.generate({ "rewrites" => list }.merge(extra.transform_keys(&:to_s)))

  def outcome_line(index, outcome, rule = nil, rewrite = nil, warnings = [])
    { "type" => "rewrite_outcome", "index" => index, "outcome" => outcome, "rule" => rule, "rewrite" => rewrite,
      "warnings" => warnings }
  end

  describe "rewrite-payload" do
    it "sends the redacted query, placeholders, plan, schema, and stats, as index-payload does" do
      ready

      outcome = quaacks.run("rewrite-payload", "--run", store.run_id)

      expect([outcome.stderr, outcome.status.exitstatus, outcome.stdout.lines.last])
        .to eq(["", 0, %({"type":"done"}\n)])
      sent = JSON.parse(outcome.stdout.lines.first)
      expect(sent.keys).to eq(%w[type query placeholders plan schema stats])
      expect(sent["type"]).to eq("rewrite_payload")
      expect(sent["query"]).to eq(stored.read("redacted_query"))
      expect(sent["placeholders"])
        .to eq(Quaack::Enclave::Steps::IndexPayload.placeholders(stored.read("placeholder_shapes")))
      expect(sent["plan"]).to eq(stored.read("redacted_plan")["explain"].map { it.except("Settings") })
      expect(sent["schema"]).to eq(schema_subset)
      expect(sent["stats"]).to eq(stored.read("classification")["outbound_statistics"])
      expect_no_leaks(sentinels, outcome)
    end
  end

  describe "rewrite-check" do
    let(:not_null_id) { { "kind" => "not_null", "table" => "public.orders", "column" => "id" } }

    it "stores an accepted rewrite as rewrite_1 and sends only its shape-only outcome" do
      ready

      outcome = rewrite_check(rewrites(rewrite(same, [not_null_id])))

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(lines(outcome)).to eq([outcome_line(1, "accepted", nil, "rewrite_1"), { "type" => "done" }])
      expect_no_leaks(sentinels, outcome)
      held = stored.read("rewrite_1")
      expect(held.keys).to eq(%w[sql transformation assumptions inferred warnings result_types])
      expect(held["sql"]).to include("public.orders")
      expect(held.slice("transformation", "assumptions", "inferred", "warnings", "result_types"))
        .to eq("transformation" => "t #{sentinels.text}", "assumptions" => [not_null_id], "inferred" => false,
               "warnings" => [], "result_types" => %w[text text])
    end

    it "numbers a later call's survivors after the earlier ones" do
      ready
      rewrite_check(rewrites(rewrite(same)))

      expect(lines(rewrite_check(rewrites(rewrite(same)))).first).to eq(outcome_line(1, "accepted", nil, "rewrite_2"))
    end

    it "rejects by the inbound check's rule, an unknown assumption kind, and step 8's structural discards" do
      ready
      outcome = rewrite_check(rewrites(
                                rewrite("SELECT o.note, o.status FROM public.orders o WHERE o.note = $3"),
                                rewrite(same, [{ "kind" => "sorted", "table" => "public.orders", "column" => "id" }]),
                                rewrite(same, [{ "kind" => "not_null", "table" => "public.orders" }]),
                                rewrite("SELECT o.note FROM public.orders o WHERE o.note = $1"),
                                rewrite("SELECT o.note, o.total FROM public.orders o WHERE o.note = $1")
                              ))
      unplannable = rewrite_check(rewrites(rewrite("SELECT o.note, o.status FROM public.orders o WHERE o.nosuch = $1")))

      expect(lines(outcome).first(5)).to eq(
        [outcome_line(1, "rejected", "bad_placeholder"), outcome_line(2, "rejected", "bad_assumption"),
         outcome_line(3, "rejected", "bad_assumption"), outcome_line(4, "rejected", "column_count_mismatch"),
         outcome_line(5, "rejected", "column_type_mismatch")]
      )
      expect(lines(unplannable).first).to eq(outcome_line(1, "rejected", "plan_failed"))
      expect(stored.entry?("rewrite_1")).to be(false)
    end

    it "checks only the first five, marking the rest too_many" do
      ready

      outcome = rewrite_check(rewrites(*Array.new(6) { rewrite(same) }))

      expect(lines(outcome).map { it["rule"] || it["rewrite"] }.first(6))
        .to eq(%w[rewrite_1 rewrite_2 rewrite_3 rewrite_4 rewrite_5 too_many])
    end

    it "refuses input that isn't a list of rewrites" do
      ready

      outcome = rewrite_check(JSON.generate("rewrites" => [{ "sql" => 1 }]))

      expect(outcome.stdout).to eq(%({"type":"error","step":"rewrite-check","rule":"rewrite_check_bad_rewrites"}\n))
    end
  end
end
