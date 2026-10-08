# frozen_string_literal: true

require "securerandom"
require "quaack/enclave/burndown"
require_relative "support/index_search_run"

# `quaacks rewrite-test`, `counterexample-payload`, and
# `counterexample-round` (DESIGN.md rewrite-test and counterexamples), the way the jump server
# runs them, on an arena of the same schema with no rows.
RSpec.describe "quaacks rewrite-test and the counterexample rounds, against a real server" do
  include_context "an index search run"

  let(:arena_name) { "quaack_arena_#{SecureRandom.hex(4)}" }
  let(:same) { "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1" }
  let(:looser) { "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1" }

  after { production.server.admin.exec(%(DROP DATABASE IF EXISTS "#{arena_name}" WITH (FORCE))) }

  def ready(sql, arena: true, setup: true, status_check: nil, arena_sql: nil)
    prepare
    store.write("schema_subset", "tables" => [%w[public orders]], "ddl" => "CREATE TABLE public.orders (id int);")
    point_at_arena
    make_arena(status_check, arena_sql) if arena
    store.write("arena_setup", true) if setup
    store.write("rewrite_1", "sql" => sql, "transformation" => "t #{sentinels.text}", "assumptions" => [],
                             "inferred" => false, "warnings" => [], "result_types" => %w[text text])
  end

  # The run server's arena, and production's TimeZone, which it runs in.
  def point_at_arena
    store.write("run_server", store.read("run_server").merge("arena_db" => arena_name))
    store.write("inventory", "settings" => { "TimeZone" => "UTC" })
  end

  # status_check, if given, becomes a CHECK on status in the arena, and
  # extra, if given, runs there after.
  def make_arena(status_check = nil, extra = nil)
    production.server.admin.exec(%(CREATE DATABASE "#{arena_name}"))
    server = production.server
    conn = PG.connect(host: server.host, port: server.port, dbname: arena_name, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec("CREATE TABLE public.orders (id int PRIMARY KEY, note text, " \
              "status text#{" CHECK (#{status_check})" if status_check}, total int, created_at timestamptz)")
    conn.exec(extra) if extra
  ensure
    conn&.close
  end

  def step(*argv, stdin: nil) = quaacks.run(*argv, "--run", store.run_id, stdin:, env: libpq_env)

  # Arena SQL for a NOT NULL foreign key cycle, orders -> accounts ->
  # orders, holding a row of rows' sentinels in each table.
  def cycle_sql(rows)
    <<~SQL
      CREATE TABLE public.accounts (id int PRIMARY KEY, order_id int NOT NULL, label text);
      INSERT INTO public.orders (id, note, status) VALUES (#{rows.number}, '#{rows.text}', '#{rows.word}');
      INSERT INTO public.accounts VALUES (#{rows.number}, #{rows.number}, '#{rows.text}');
      ALTER TABLE public.orders ADD COLUMN account_id int;
      UPDATE public.orders SET account_id = #{rows.number};
      ALTER TABLE public.orders ALTER COLUMN account_id SET NOT NULL;
      ALTER TABLE public.orders ADD FOREIGN KEY (account_id) REFERENCES public.accounts;
      ALTER TABLE public.accounts ADD FOREIGN KEY (order_id) REFERENCES public.orders;
    SQL
  end

  def lines(outcome) = outcome.stdout.lines.map { JSON.parse(it) }

  def burndown = Quaack::Enclave::Burndown.read(stored)
  def remove(entry) = FileUtils.rm_f(File.join(stored.path, "#{entry}.json"))

  def counted(**counts)
    { "in" => 1, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 0, "extra" => {} }
      .merge(counts.transform_keys(&:to_s))
  end

  def round(number, *inserts)
    step("counterexample-round", "--search", "rewrite_1", "--round", number.to_s,
         stdin: JSON.generate("inserts" => inserts))
  end

  describe "rewrite-test" do
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

    # QUAACKS_PROFILE (Profiler) writes code locations to a file on the jump
    # server, never values, and the step prints what it would without it.
    it "writes a profile of code locations only when QUAACKS_PROFILE is set, and prints the same" do
      ready(looser)
      profile = File.join(quaacks.home, "profile.txt")

      outcome = quaacks.run("rewrite-test", "--search", "rewrite_1", "--run", store.run_id,
                            env: libpq_env.merge("QUAACKS_PROFILE" => profile))

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(lines(outcome).first).to include("passed" => false, "scenario" => "s1", "rule" => "row_count")
      header, *rows = File.read(profile).lines
      expect(header).to match(/\A# quaacks profile: [1-9]\d* samples\./)
      expect(rows).to all(match(/\A\d+\t\d+\t[^\t]+:\d+\n\z/))
      expect(rows.join).to include("/quaack/enclave/cli.rb:")
      expect_no_leaks(sentinels, stdout: File.read(profile), why: "the profile")
      expect(LeakCheck.findings(sentinels, stdout: "#{rows.first}#{sentinels.text}\n")).not_to eq([])
    end

    it "disproves a looser rewrite by scenario and rule, and records that it didn't survive" do
      ready(looser)

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect(lines(outcome).first).to include("passed" => false, "scenario" => "s1", "rule" => "row_count")
      expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
      expect_no_leaks(sentinels, outcome)
    end

    it "marks the rewrite untested when rewrite-test can't build scenarios, by the refusal's rule, and goes on" do
      ready(same, status_check: "status = 'open' OR status = 'closed'")

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(lines(outcome)).to eq([{ "type" => "rewrite_test", "rewrite" => "rewrite_1", "passed" => false,
                                      "scenario" => nil, "rule" => "complex_check" }, { "type" => "done" }])
      expect(stored.read("rewrite_tested_1"))
        .to eq("passed" => false, "scenario" => nil, "rule" => "complex_check", "refused" => true,
               "untested" => [], "untested_atoms" => [])
      expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
      expect_no_leaks(sentinels, outcome)
    end

    # The refusal's error names the column and its type; only the rule may
    # leave rewrite-test, on stdout or into the store that report-payload reads.
    it "keeps the column and type a refusal names out of its output and the store" do
      column = LeakCheck::Sentinels.new
      domain = LeakCheck::Sentinels.new
      ready(same, arena_sql: "CREATE DOMAIN public.#{domain.word} AS int CHECK (VALUE > 5 AND VALUE < 3); " \
                             "ALTER TABLE public.orders ADD COLUMN #{column.word} public.#{domain.word} NOT NULL")

      outcome = step("rewrite-test", "--search", "rewrite_1")

      tested = stored.read("rewrite_tested_1")
      expect(tested).to include("refused" => true)
      [column, domain].each { expect_no_leaks(it, outcome, objects: { tested: }) }
      expect(tested).to include("rule" => "domain_check")
    end

    # An fk_cycle refusal keeps the cycle's tables, which are schema, in the
    # store for the report: never a row of theirs, on stdout or in the store.
    it "stores the tables of an fk_cycle refusal, in the order their foreign keys point, and no row value" do
      rows = LeakCheck::Sentinels.new
      ready(same, arena_sql: cycle_sql(rows))

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect(lines(outcome)).to eq([{ "type" => "rewrite_test", "rewrite" => "rewrite_1", "passed" => false,
                                      "scenario" => nil, "rule" => "fk_cycle" }, { "type" => "done" }])
      tested = stored.read("rewrite_tested_1")
      expect(tested).to include("refused" => true, "rule" => "fk_cycle",
                                "cycle" => [%w[public orders], %w[public accounts], %w[public orders]])
      expect_no_leaks(rows, outcome, objects: { tested: })
      expect_no_leaks(sentinels, outcome, objects: { tested: })
    end

    it "skips a rewrite plan-pruning discarded, without connecting to the arena" do
      ready(same, arena: false)
      store.write("rewrite_pruned_1", "discarded" => true)

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect(lines(outcome).first).to include("passed" => false, "rule" => "discarded")
      expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
    end

    it "reports rewrite-test and survival progress in status" do
      ready(looser)
      before = JSON.parse(step("status").stdout.lines.first)["entries"]
      step("rewrite-test", "--search", "rewrite_1")
      after = JSON.parse(step("status").stdout.lines.first)["entries"]

      expect([before, after].map { it.slice("rewrite_tested_1", "rewrite_survived_1") })
        .to eq([{ "rewrite_tested_1" => false, "rewrite_survived_1" => false },
                { "rewrite_tested_1" => true, "rewrite_survived_1" => true }])
    end

    it "refuses to test, or run a round, before the arena is set up (arena-setup)" do
      ready(same, setup: false)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      expect(lines(step("rewrite-test", "--search", "rewrite_1")).first["rule"]).to eq("rewrite_test_no_arena_setup")
      expect(lines(round(1)).first["rule"]).to eq("counterexample_round_no_arena_setup")
    end

    it "refuses a search that isn't a stored rewrite" do
      ready(same)

      expect(lines(step("rewrite-test", "--search", "rewrite_9")).first["rule"]).to eq("rewrite_test_unknown_search")
    end

    context "with now() and an anchor far from the real clock (DESIGN.md's clock-anchor)" do
      let(:query) do
        "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held' " \
          "AND o.created_at < now()"
      end

      it "runs the candidate's anchored_sql, so an equivalent candidate passes" do
        ready(same)
        conn = PG.connect(host: production.server.host, port: production.server.port, dbname: arena_name,
                          user: TestPostgres::USER, password: TestPostgres::PASSWORD)
        conn.exec("CREATE SCHEMA quaack")
        conn.exec("CREATE FUNCTION quaack.clock_anchor() RETURNS pg_catalog.timestamptz LANGUAGE sql IMMUTABLE " \
                  "AS $$SELECT '2000-01-01 00:00:00+00'::pg_catalog.timestamptz$$")
        conn.close
        candidate = "SELECT o.note, o.status FROM public.orders o WHERE o.created_at < %s AND o.status = $2 " \
                    "AND o.note = $1"
        store.write("rewrite_1", store.read("rewrite_1").merge("sql" => format(candidate, "now()"),
                                                               "anchored_sql" => format(candidate,
                                                                                        "quaack.clock_anchor()")))

        expect(lines(step("rewrite-test", "--search", "rewrite_1")).first).to include("passed" => true)
      end
    end
  end

  describe "rewrite-test's burndown" do
    def test = step("rewrite-test", "--search", "rewrite_1")
    def none = { "untested_atoms" => 0, "vacuity_guard_retries" => 0 }

    it "records a rewrite that passed under its search, with untested atoms, vacuity-guard retries, and loads" do
      # No row can fail o.status = 'held', so vacuity-guard leaves it untested.
      ready(same, status_check: "status = 'held'")

      test

      expect(burndown["stages"]).to eq(
        "rewrite-test" => { "rewrite_1" => counted(out: 1, extra: { "untested_atoms" => 1,
                                                                    "vacuity_guard_retries" => 3 }) }
      )
      expect(burndown["totals"]).to eq("fixture_loads" => 18)
    end

    it "drops a disproved rewrite by its scenario, and an untested one by the refusal's rule" do
      ready(looser)
      test
      expect(burndown["stages"]["rewrite-test"]).to eq("rewrite_1" => counted(dropped: { "s1" => 1 }, extra: none))

      production.server.admin.exec(%(DROP DATABASE "#{arena_name}" WITH (FORCE)))
      make_arena("status = 'open' OR status = 'closed'")
      store.write("rewrite_2", stored.read("rewrite_1").merge("sql" => same))
      step("rewrite-test", "--search", "rewrite_2")
      expect(burndown["stages"]["rewrite-test"]["rewrite_2"]).to eq(counted(dropped: { "complex_check" => 1 },
                                                                            extra: none))
    end

    it "records nothing for a rewrite plan-pruning pruned, which never reached rewrite-test" do
      ready(same, arena: false)
      store.write("rewrite_pruned_1", "discarded" => true)

      test

      expect(burndown).to eq("stages" => {}, "totals" => {})
    end

    it "counts nothing twice when a call that died before its entry is run again" do
      ready(looser)
      test
      first = burndown
      %w[rewrite_tested_1 rewrite_survived_1].each { remove(it) }

      test

      expect(stored.read("rewrite_tested_1")).to include("passed" => false)
      expect(burndown).to eq(first)
    end

    # Task 20261004-69: the rerun's outcome differs (here, the rewrite is
    # now the equivalent one), so its record replaces the dead call's. The
    # fixtures the dead call loaded stay counted once.
    it "keeps the latest outcome's record when a call that died before its entry is run again differently" do
      ready(looser)
      test
      loads = burndown["totals"]
      %w[rewrite_tested_1 rewrite_survived_1].each { remove(it) }
      store.write("rewrite_1", stored.read("rewrite_1").merge("sql" => same))

      test

      expect(stored.read("rewrite_tested_1")).to include("passed" => true)
      expect(burndown["stages"]["rewrite-test"]["rewrite_1"]).to include("in" => 1, "dropped" => {}, "out" => 1)
      expect(burndown["totals"]).to eq(loads)
    end
  end

  describe "counterexamples' burndown" do
    let(:note_row) { "INSERT INTO public.orders (id, note, status) VALUES (1, $1, 'open')" }
    let(:dup_rows) { "INSERT INTO public.orders (id, note, status) VALUES (1, $1, 'open'), (1, $1, 'open')" }

    it "drops a rewrite disproved by the round that disproved it, adding up every round's fixture loads" do
      ready(looser)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      round(1, dup_rows)
      expect(burndown).to eq("stages" => {}, "totals" => {})
      round(2, note_row)

      expect(burndown).to eq("stages" => { "counterexamples" => { "rewrite_1" => counted(
        dropped: { "round_2" => 1 }, extra: { "atoms_covered" => 0 }
      ) } }, "totals" => { "fixture_loads" => 3 })
    end

    # RewriteFate calls this counterexamples_failed, not a disproof, so the
    # burndown mustn't say the round proved it wrong.
    it "drops a rewrite that failed to run in a round as failed in that round, not as disproved" do
      ready("SELECT o.note, (o.id / 0)::text FROM public.orders o WHERE o.note = $1")
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      round(1, note_row)

      expect(stored.read("rewrite_round_1")).to include("rule" => "query_failed")
      expect(burndown["stages"]).to eq("counterexamples" => { "rewrite_1" => counted(
        dropped: { "failed_in_round_1" => 1 }, extra: { "atoms_covered" => 0 }
      ) })
    end

    it "keeps a survivor of round 3, with the untested atoms the rounds covered, and counts it once when rerun" do
      ready(same)
      # The original reads o.note = $1 AND o.status = $2: atom 1 is the status test.
      store.write("rewrite_tested_1", "passed" => true, "untested" => ["o.status = $2"], "untested_atoms" => [1])
      round(1, note_row)
      round(2, dup_rows)
      round(3, dup_rows)
      first = burndown
      expect(first).to eq("stages" => { "counterexamples" => { "rewrite_1" => counted(
        out: 1, extra: { "atoms_covered" => 1 }
      ) } }, "totals" => { "fixture_loads" => 5 })
      remove("rewrite_survived_1")

      [note_row, dup_rows, dup_rows].each.with_index(1) { |insert, number| round(number, insert) }

      expect(stored.read("rewrite_survived_1")).to include("survived" => true)
      expect(burndown).to eq(first)
    end

    # Task 20261004-69: a round that disproved the rewrite died before
    # rewrite_survived_<n>; the rerun's rounds, on the equivalent rewrite,
    # all match, so the survivor's record replaces the disproof's.
    it "keeps the latest outcome's record when rounds that died before deciding are run again differently" do
      ready(looser)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])
      round(1, note_row)
      expect(burndown["stages"]["counterexamples"]["rewrite_1"]["dropped"]).to eq("round_1" => 1)
      remove("rewrite_survived_1")
      store.write("rewrite_1", stored.read("rewrite_1").merge("sql" => same))

      [note_row, dup_rows, dup_rows].each.with_index(1) { |insert, number| round(number, insert) }

      expect(stored.read("rewrite_survived_1")).to include("survived" => true)
      expect(burndown["stages"]["counterexamples"]["rewrite_1"]).to include("dropped" => {}, "out" => 1)
    end
  end

  describe "counterexample-payload (llm-counterexamples)" do
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

    it "sends rewrite-test's untested atom shapes" do
      # No row can fail o.status = 'held', so vacuity-guard leaves it untested.
      ready(same, status_check: "status = 'held'")
      expect(lines(step("rewrite-test", "--search", "rewrite_1")).first).to include("passed" => true)

      sent = lines(step("counterexample-payload", "--search", "rewrite_1")).first

      expect(sent["untested_atoms"]).to eq(["o.status = $2"])
    end
  end

  describe "counterexample-round (counterexample-compare and counterexample-rollback)" do
    let(:note_row) { "INSERT INTO public.orders (id, note, status) VALUES (1, $1, 'open')" }
    let(:dup_rows) { "INSERT INTO public.orders (id, note, status) VALUES (1, $1, 'open'), (1, $1, 'open')" }

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
      # The round's rule is stored, so the report can tell a mismatch from
      # a candidate that failed to run (20261001-17).
      expect(stored.read("rewrite_round_1"))
        .to eq("round" => 1, "evidence" => true, "rule" => "row_count", "covered" => [], "fixture_loads" => 2)
      expect_no_leaks(sentinels, outcome)
    end

    it "builds a parent row that leaves NULL a nullable column rewrite-test can't fill, when neither query reads it" do
      ready(same, arena_sql: "CREATE TABLE public.customers (id int PRIMARY KEY, lsn pg_lsn);
                              ALTER TABLE public.orders ADD customer_id int REFERENCES public.customers")
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      outcome = round(1, "INSERT INTO public.orders (id, note, status, customer_id) VALUES (1, $1, 'open', 7)")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0]), outcome.stdout
      expect(lines(outcome).first).to include("match" => true, "load_failed" => false, "refused" => [])
    end

    it "refuses by rule alone an insert whose bound value Postgres can't evaluate, and runs the round (20261003-24)" do
      ready(same, arena_sql: "CREATE TABLE public.customers (id int PRIMARY KEY);
                              ALTER TABLE public.orders ADD customer_id int REFERENCES public.customers")
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      outcome = round(1, note_row, "INSERT INTO public.orders (id, status, customer_id) VALUES (2, 'open', $1::int)")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0]), outcome.stdout
      expect(lines(outcome).first).to include("match" => true, "load_failed" => false,
                                              "refused" => [{ "index" => 1, "rule" => "bad_value" }])
      expect_no_leaks(sentinels, outcome)
    end

    # Task 20261007-34: the arena connects as the run server's role, and
    # its session's search_path is the run's stored one, so an insert's
    # function resolves there through that path, not through a "$user"
    # that names the run server's role.
    it "checks an insert's functions through the run's stored search_path" do
      role = PG::Connection.quote_ident(production.user)
      ready(same, arena_sql: <<~SQL)
        CREATE SCHEMA #{role};
        CREATE FUNCTION #{role}.twice(int) RETURNS int VOLATILE LANGUAGE sql AS 'SELECT $1 * 2';
        CREATE FUNCTION public.twice(int) RETURNS int IMMUTABLE LANGUAGE sql AS 'SELECT $1 * 2';
      SQL
      store.write("search_path", %w[public])
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      outcome = round(1, "INSERT INTO public.orders (id, note, total) VALUES (1, $1, twice(2))")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0]), outcome.stdout
      expect(lines(outcome).first).to include("match" => true, "load_failed" => false, "refused" => [])
    end

    # public.slow sleeps, and claims IMMUTABLE so the inbound check lets
    # the cast through; the arena's statement_timeout cuts it short.
    it "reports a statement timeout while evaluating a value as the step's error, not as bad_value" do
      ready(same, arena_sql: <<~SQL)
        CREATE FUNCTION public.slow(int) RETURNS boolean LANGUAGE plpgsql IMMUTABLE
          AS 'BEGIN PERFORM pg_sleep(5); RETURN true; END';
        CREATE DOMAIN public.slow_int AS int CHECK (public.slow(VALUE));
        ALTER DATABASE "#{arena_name}" SET statement_timeout = 300;
      SQL
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      outcome = round(1, "INSERT INTO public.orders (id, note, total) VALUES (1, $1, 5::public.slow_int)")

      expect(lines(outcome)).to eq([{ "type" => "error", "step" => "counterexample-round",
                                      "rule" => "internal_error", "sqlstate" => "57014" }])
      expect_no_leaks(sentinels, outcome)
    end

    it "decides survival only after a matching third round" do
      ready(same)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      expect(lines(round(1, note_row)).first).to include("match" => true)
      expect(stored.entry?("rewrite_survived_1")).to be(false)
      expect(stored.read("rewrite_round_1"))
        .to eq("round" => 1, "evidence" => true, "rule" => nil, "covered" => [], "fixture_loads" => 3)
      round(2, dup_rows)
      round(3, dup_rows)
      expect(stored.read("rewrite_survived_1")).to eq("survived" => true, "evidence" => true)
    end

    it "records the untested atoms' shapes the rounds covered so far, and starts over at round 1" do
      ready(same)
      # The original reads o.note = $1 AND o.status = $2: atom 1 is the status test.
      store.write("rewrite_tested_1", "passed" => true, "untested" => ["o.status = $2"], "untested_atoms" => [1])

      expect(lines(round(1, note_row)).first).to include("match" => true, "covered" => ["o.status = $2"])
      expect(stored.read("rewrite_round_1")).to include("round" => 1, "covered" => ["o.status = $2"])
      expect(lines(round(2, dup_rows)).first).to include("load_failed" => true, "covered" => [])
      expect(stored.read("rewrite_round_1")).to include("round" => 2, "covered" => ["o.status = $2"])
      expect(lines(round(1, dup_rows)).first).to include("covered" => [])
      expect(stored.read("rewrite_round_1")).to include("round" => 1, "covered" => [])
    end

    it "marks a survivor whose inserts never loaded as having no evidence" do
      ready(same)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      expect(lines(round(1, dup_rows)).first).to include("load_failed" => true)
      round(2, dup_rows)
      round(3, dup_rows)
      expect(stored.read("rewrite_survived_1")).to eq("survived" => true, "evidence" => false)
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

    it "refuses a round before rewrite-test passed, and a round number outside 1 to 3" do
      ready(same)

      expect(lines(round(1, note_row)).first["rule"]).to eq("counterexample_round_untested")
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])
      expect(lines(round(4, note_row)).first["rule"]).to eq("counterexample_round_bad_round")
    end

    # rewrite-test refuses an fk_cycle first, so a round meets one only if the
    # arena changed after it; its error line still names the cycle's tables,
    # but only those of the schema subset, and never a row of theirs.
    context "when the arena's foreign keys make a NOT NULL cycle" do
      let(:rows) { LeakCheck::Sentinels.new }

      def cycle_ready(subset)
        ready(same, arena_sql: cycle_sql(rows))
        store.write("schema_subset", "tables" => subset, "ddl" => "CREATE TABLE public.orders (id int);")
        store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])
      end

      it "ends the round naming the cycle's tables, in the order their foreign keys point" do
        cycle_ready([%w[public orders], %w[public accounts]])

        outcome = round(1, note_row)

        expect(lines(outcome).first).to include("type" => "error", "step" => "counterexample-round",
                                                "rule" => "fk_cycle",
                                                "cycle" => %w[public.orders public.accounts public.orders])
        expect_no_leaks(rows, outcome)
        expect_no_leaks(sentinels, outcome)
      end

      it "names no table when one of the cycle's isn't in the schema subset" do
        cycle_ready([%w[public orders]])

        outcome = round(1, note_row)

        expect(lines(outcome).first).to include("type" => "error", "rule" => "fk_cycle")
        expect(lines(outcome).first).not_to have_key("cycle")
        expect_no_leaks(rows, outcome)
      end
    end
  end
end
