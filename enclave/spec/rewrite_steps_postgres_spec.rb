# frozen_string_literal: true

require "quaack/enclave/assumption_check"
require "quaack/enclave/steps/index_payload"
require_relative "support/index_search_run"

# `quaacks rewrite-payload` and `quaacks rewrite-check` (DESIGN.md's llm-rewrites and assumption-check,
# with structural-discard), the way the jump server runs them.
RSpec.describe "quaacks rewrite-payload and rewrite-check, against a real server" do
  include_context "an index search run"

  # The query's table and its FK parent, as schema-dump stores them.
  let(:schema_subset) do
    { "tables" => [%w[public orders], %w[public customers]],
      "ddl" => "CREATE TABLE public.customers (id integer);\nCREATE TABLE public.orders (id integer);\n" }
  end
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
        .to eq(Quaack::Enclave::Steps::IndexPayload.placeholders(stored))
      expect(sent["plan"]).to eq(stored.read("redacted_plan")["explain"].map { it.except("Settings") })
      expect(sent["schema"])
        .to eq("tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id integer);\n")
      expect(sent["stats"]).to eq(stored.read("classification")["outbound_statistics"])
      expect_no_leaks(sentinels, outcome)
    end

    context "with a timestamptz range, after index-search" do
      let(:query) do
        "SELECT o.note FROM public.orders o WHERE o.note = '#{sentinels.text}' " \
          "AND o.created_at >= '2026-09-01' AND o.created_at < '2026-09-02'"
      end

      it "types each placeholder as Postgres infers it for the query" do
        ready
        index_search

        sent = JSON.parse(quaacks.run("rewrite-payload", "--run", store.run_id).stdout.lines.first)

        expect(sent["placeholders"].transform_values { it["type"] })
          .to eq("$1" => "text", "$2" => "timestamp with time zone", "$3" => "timestamp with time zone")
      end
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
      expect(held.keys).to eq(%w[sql transformation assumptions inferred warnings result_types anchored_sql source])
      expect(held["sql"]).to include("public.orders")
      expect(held.slice("transformation", "assumptions", "inferred", "warnings", "result_types", "source"))
        .to eq("transformation" => "t #{sentinels.text}", "assumptions" => [not_null_id], "inferred" => false,
               "warnings" => [], "result_types" => %w[text text], "source" => "llm")
    end

    it "records that llm-rewrites ran when the LLM proposed no rewrites" do
      ready

      outcome = rewrite_check(rewrites)

      expect([lines(outcome), outcome.status.exitstatus]).to eq([[{ "type" => "done" }], 0])
      expect(stored.entry?("rewrites_generated")).to be(true)
      expect(stored.entry?("rewrite_1")).to be(false)
    end

    it "numbers a later call's survivors after the earlier ones" do
      ready
      rewrite_check(rewrites(rewrite(same)))

      expect(lines(rewrite_check(rewrites(rewrite(same)))).first).to eq(outcome_line(1, "accepted", nil, "rewrite_2"))
    end

    it "rejects by the inbound check's rule, an unknown assumption kind, and structural-discard" do
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
         outcome_line(3, "rejected", "bad_assumption"), outcome_line(4, "rejected", "output_mismatch"),
         outcome_line(5, "rejected", "output_mismatch")]
      )
      expect(lines(unplannable).first).to eq(outcome_line(1, "rejected", "failed_to_plan"))
      expect(stored.entry?("rewrite_1")).to be(false)
    end

    it "rejects a rewrite with an unmet assumption (assumption-check), after planning it and before any timed run" do
      ready

      outcome = rewrite_check(rewrites(rewrite(same, [not_null_id.merge("column" => "note")])))

      expect(lines(outcome).first).to eq(outcome_line(1, "rejected", "unmet_assumption"))
      expect(stored.entry?("rewrite_1")).to be(false)
    end

    it "keeps an operator's inferred rewrite with an unmet assumption, as a warning of its position and kind" do
      ready
      unmet = not_null_id.merge("column" => "note")

      outcome = rewrite_check(rewrites(*Array.new(6) { rewrite(same, [not_null_id, unmet]) }, inferred: true))

      warning = [{ "assumption" => 2, "kind" => "not_null" }]
      expect(lines(outcome).first).to eq(outcome_line(1, "accepted", nil, "rewrite_1", warning))
      expect(lines(outcome)[5]["rewrite"]).to eq("rewrite_6")
      expect_no_leaks(sentinels, outcome)
      expect(stored.read("rewrite_1").slice("inferred", "warnings", "source"))
        .to eq("inferred" => true, "warnings" => warning, "source" => "operator")
    end

    # denormalized_equal is checked against the data (assumption-check), which only a rewrite-rules
    # rule may ask for: the LLM or the operator could otherwise make the
    # enclave probe any table it names.
    context "with a denormalized_equal assumption, which only a rewrite-rules rule may state" do
      let(:denormalized) do
        { "kind" => "denormalized_equal", "table" => "public.probe_children", "column" => "parent_copy",
          "join_column" => "parent_id", "references_table" => "public.probe_parents", "references_column" => "id",
          "type_column" => "kind", "type_value" => "K", "id_column" => "copy" }
      end

      # The data holds the assumption, so a probe would find it met.
      def make_probe_tables
        production.connect.tap do |conn|
          conn.exec(<<~SQL)
            CREATE TABLE public.probe_parents (id int PRIMARY KEY, kind text, copy int);
            CREATE TABLE public.probe_children (id int PRIMARY KEY, parent_id int, parent_copy int);
            INSERT INTO public.probe_parents SELECT i, 'K', i * 10 FROM generate_series(1, 20) i;
            INSERT INTO public.probe_children SELECT i, i, i * 10 FROM generate_series(1, 20) i;
          SQL
        ensure
          conn.close
        end
      end

      # Every scan of the probe tables Postgres has counted. A backend
      # flushes its counts when it exits, so this waits for them to settle.
      def probe_scans
        conn = production.connect
        counts = Array.new(3) do
          sleep 0.5
          conn.exec("SELECT coalesce(sum(seq_scan + coalesce(idx_scan, 0)), 0) FROM pg_stat_user_tables " \
                    "WHERE relname IN ('probe_children', 'probe_parents')").getvalue(0, 0).to_i
        end
        counts.last
      ensure
        conn&.close
      end

      it "refuses it from the LLM or an operator as a bad assumption, and never probes the data" do
        ready
        make_probe_tables
        before = probe_scans

        llm = rewrite_check(rewrites(rewrite(same, [denormalized])))
        operator = rewrite_check(rewrites(rewrite(same, [denormalized]), inferred: true))

        expect(lines(llm).first).to eq(outcome_line(1, "rejected", "bad_assumption"))
        expect(lines(operator).first).to eq(outcome_line(1, "rejected", "bad_assumption"))
        expect(probe_scans).to eq(before)
        expect(stored.entry?("rewrite_1")).to be(false)
      end

      it "would see a probe in the scan counts, so the check above can fail" do
        ready
        make_probe_tables
        before = probe_scans
        conn = production.connect

        expect(Quaack::Enclave::AssumptionCheck.met?(denormalized, conn)).to be(true)
        conn.close
        expect(probe_scans).to be > before
      end
    end

    it "checks an operator's rewrite by the same inbound check" do
      ready

      outcome = rewrite_check(rewrites(rewrite("SELECT o.note FROM public.orders o"), inferred: true))

      expect(lines(outcome).first).to eq(outcome_line(1, "rejected", "output_mismatch"))
    end

    it "records that operator-rewrites ran for an inferred call, and llm-rewrites only for a stated one" do
      ready

      rewrite_check(rewrites(inferred: true))

      expect(%w[operator_rewrites_checked rewrites_generated].map { stored.entry?(it) }).to eq([true, false])
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
