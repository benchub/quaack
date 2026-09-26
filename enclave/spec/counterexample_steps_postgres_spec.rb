# frozen_string_literal: true

require "securerandom"
require_relative "support/index_search_run"

# `quaacks rewrite-test`, `counterexample-payload`, and
# `counterexample-round` (README steps 9 and 10), the way the jump server
# runs them, on an arena of the same schema with no rows.
RSpec.describe "quaacks rewrite-test and the counterexample rounds, against a real server" do
  include_context "an index search run"

  let(:arena_name) { "quaack_arena_#{SecureRandom.hex(4)}" }
  let(:same) { "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1" }
  let(:looser) { "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1" }

  after { production.server.admin.exec(%(DROP DATABASE IF EXISTS "#{arena_name}" WITH (FORCE))) }

  def ready(sql, arena: true, setup: true)
    prepare
    store.write("schema_subset", "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id int);")
    store.write("run_server", store.read("run_server").merge("arena_db" => arena_name))
    make_arena if arena
    store.write("arena_setup", true) if setup
    store.write("rewrite_1", "sql" => sql, "transformation" => "t #{sentinels.text}", "assumptions" => [],
                             "inferred" => false, "warnings" => [], "result_types" => %w[text text])
  end

  def make_arena
    production.server.admin.exec(%(CREATE DATABASE "#{arena_name}"))
    server = production.server
    conn = PG.connect(host: server.host, port: server.port, dbname: arena_name, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec("CREATE TABLE public.orders (id int PRIMARY KEY, note text, status text, total int, " \
              "created_at timestamptz)")
  ensure
    conn&.close
  end

  def step(*argv, stdin: nil) = quaacks.run(*argv, "--run", store.run_id, stdin:, env: libpq_env)
  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }

  def round(number, *inserts)
    step("counterexample-round", "--search", "rewrite_1", "--round", number.to_s,
         stdin: JSON.generate("inserts" => inserts))
  end

  describe "rewrite-test (step 9)" do
    it "passes an equivalent rewrite, stores its result, and doesn't decide survival yet" do
      ready(same)

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(lines(outcome)).to eq([{ "type" => "rewrite_test", "rewrite" => "rewrite_1", "passed" => true,
                                      "scenario" => nil, "rule" => nil }, { "type" => "done" }])
      expect(stored.read("rewrite_tested_1")).to include("passed" => true)
      expect(stored.entry?("rewrite_survived_1")).to be(false)
      expect_no_leaks(sentinels, outcome)
    end

    it "disproves a looser rewrite by scenario and rule, and records that it didn't survive" do
      ready(looser)

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect(lines(outcome).first).to include("passed" => false, "scenario" => "s1", "rule" => "row_count")
      expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
      expect_no_leaks(sentinels, outcome)
    end

    it "skips a rewrite step 8 discarded, without connecting to the arena" do
      ready(same, arena: false)
      store.write("rewrite_pruned_1", "discarded" => true)

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect(lines(outcome).first).to include("passed" => false, "rule" => "discarded")
      expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
    end

    it "reports step 9 and survival progress in status" do
      ready(looser)
      before = JSON.parse(step("status").stdout.lines.first)["entries"]
      step("rewrite-test", "--search", "rewrite_1")
      after = JSON.parse(step("status").stdout.lines.first)["entries"]

      expect([before, after].map { it.slice("rewrite_tested_1", "rewrite_survived_1") })
        .to eq([{ "rewrite_tested_1" => false, "rewrite_survived_1" => false },
                { "rewrite_tested_1" => true, "rewrite_survived_1" => true }])
    end

    it "refuses to test, or run a round, before the arena is set up (4b)" do
      ready(same, setup: false)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      expect(lines(step("rewrite-test", "--search", "rewrite_1")).first["rule"]).to eq("rewrite_test_no_arena_setup")
      expect(lines(round(1)).first["rule"]).to eq("counterexample_round_no_arena_setup")
    end

    it "refuses a search that isn't a stored rewrite" do
      ready(same)

      expect(lines(step("rewrite-test", "--search", "rewrite_9")).first["rule"]).to eq("rewrite_test_unknown_search")
    end
  end

  describe "counterexample-payload (10a)" do
    it "sends the redacted original, the candidate's SQL, placeholders, schema, and untested atoms" do
      ready(same)
      step("rewrite-test", "--search", "rewrite_1")

      outcome = step("counterexample-payload", "--search", "rewrite_1")

      sent = lines(outcome).first
      expect(sent.keys).to eq(%w[type original candidate placeholders schema untested_atoms])
      expect(sent.slice("original", "candidate", "untested_atoms"))
        .to eq("original" => stored.read("redacted_query"), "candidate" => { "sql" => same }, "untested_atoms" => [])
      expect_no_leaks(sentinels, outcome)
    end

    it "sends step 9's untested atom shapes" do
      ready(same)
      store.write("rewrite_tested_1", "passed" => true, "untested" => ["o.status = $2"], "untested_atoms" => [1])

      sent = lines(step("counterexample-payload", "--search", "rewrite_1")).first

      expect(sent["untested_atoms"]).to eq(["o.status = $2"])
    end
  end

  describe "counterexample-round (10b and 10c)" do
    let(:note_row) { "INSERT INTO public.orders (id, note, status) VALUES (1, $1, 'open')" }

    it "finds a mismatch, binding $n to the real literal, and records the rewrite didn't survive" do
      ready(looser)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      outcome = round(1, note_row, "INSERT INTO public.orders (id) SELECT 1")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(lines(outcome).first).to eq("type" => "counterexample_round", "match" => false, "rule" => "row_count",
                                         "load_order" => lines(outcome).first["load_order"], "covered" => [],
                                         "refused" => [{ "index" => 1, "rule" => "insert_select" }],
                                         "load_failed" => false)
      expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
      expect_no_leaks(sentinels, outcome)
    end

    it "decides survival only after a matching third round" do
      ready(same)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      expect(lines(round(1, note_row)).first).to include("match" => true)
      expect(stored.entry?("rewrite_survived_1")).to be(false)
      round(2, note_row)
      round(3, note_row)
      expect(stored.read("rewrite_survived_1")).to eq("survived" => true)
    end

    it "refuses a round out of sequence, and any round once survival is decided" do
      ready(looser)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      expect(lines(round(3, note_row)).first["rule"]).to eq("counterexample_round_out_of_order")
      expect(stored.entry?("rewrite_survived_1")).to be(false)
      round(1, note_row)
      expect(lines(round(2, note_row)).first["rule"]).to eq("counterexample_round_decided")
      expect(lines(round(1, note_row)).first["rule"]).to eq("counterexample_round_decided")
      expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
    end

    it "refuses a round before step 9 passed, and a round number outside 1 to 3" do
      ready(same)

      expect(lines(round(1, note_row)).first["rule"]).to eq("counterexample_round_untested")
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])
      expect(lines(round(4, note_row)).first["rule"]).to eq("counterexample_round_bad_round")
    end
  end
end
