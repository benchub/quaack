# frozen_string_literal: true

require "securerandom"
require "quaack/enclave/burndown"
require "quaack/enclave/steps/report_payload"
require "quaack/enclave/steps/counterexamples"
require "quaack/enclave/steps/rule_bugs"
require "quaack/enclave/egress"
require "quaack/enclave/deadline"
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
                             "anchored_sql" => sql, "inferred" => false, "warnings" => [],
                             "result_types" => %w[text text])
  end

  # The run server's arena, and production's TimeZone, which it runs in.
  def point_at_arena
    store.write("run_server", store.read("run_server").merge("arena_db" => arena_name))
    store.write("inventory", "settings" => { "TimeZone" => "UTC" })
  end

  # status_check, if given, becomes a CHECK on status in the arena, and
  # makes it NOT NULL, so no row fails a status the CHECK pins (a NULL
  # status would, and vacuity-guard's search would find it), and
  # extra, if given, runs there after.
  def make_arena(status_check = nil, extra = nil)
    production.server.admin.exec(%(CREATE DATABASE "#{arena_name}"))
    server = production.server
    conn = PG.connect(host: server.host, port: server.port, dbname: arena_name, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec("CREATE TABLE public.orders (id int PRIMARY KEY, note text, " \
              "status text#{" NOT NULL CHECK (#{status_check})" if status_check}, total int, created_at timestamptz)")
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

  # A candidate whose query sleeps once, so a second session can cancel it.
  let(:sleepy) { "#{same} AND (SELECT length(pg_sleep(30)::text)) >= 0" }

  # Runs the block while a second session cancels the arena backend that
  # sleeps in pg_sleep, as an operator's pg_cancel_backend would, and
  # returns the block's value and whether a cancel was sent.
  def cancel_arena_sleeper
    canceller = Thread.new { 400.times.any? { canceled_sleeper? || (sleep(0.05) && false) } }
    value = yield
    [value, canceller.value]
  ensure
    canceller&.kill
  end

  # Cancels the arena's backend in pg_sleep, from the admin session, and
  # says whether there was one.
  def canceled_sleeper?
    production.server.admin.exec_params(<<~SQL, [arena_name]).ntuples.positive?
      SELECT pg_cancel_backend(pid) FROM pg_stat_activity
      WHERE datname = $1 AND wait_event = 'PgSleep' AND pid <> pg_backend_pid()
    SQL
  end

  # Arena SQL for a nap() that sleeps once, the first time it runs with
  # orders' foreign key to customers in place: in a lift, which enforces
  # every constraint, never in fuzz's session, which drops it. A sequence
  # counts the runs, since no rollback resets it.
  let(:napping) do
    <<~SQL
      CREATE TABLE public.customers (id int PRIMARY KEY);
      ALTER TABLE public.orders ADD COLUMN customer_id int REFERENCES public.customers;
      CREATE SEQUENCE public.naps;
      CREATE FUNCTION public.nap() RETURNS boolean LANGUAGE plpgsql AS $$
        BEGIN
          IF EXISTS (SELECT FROM pg_constraint WHERE conname = 'orders_customer_id_fkey')
             AND nextval('public.naps') = 1 THEN
            PERFORM pg_sleep(30);
          END IF;
          RETURN true;
        END $$;
    SQL
  end

  # Whether the step stored no result, survival, or burndown for rewrite_1.
  def stored_nothing?
    stages = Quaack::Enclave::Burndown.read(stored).fetch("stages", {})
    %w[rewrite_tested_1 rewrite_survived_1].none? { stored.entry?(it) } &&
      stages.values.none? { it.key?("rewrite_1") }
  end

  let(:rewrite_test) { Quaack::Enclave::Steps::Counterexamples::RewriteTest }

  # rewrite-test in this process, as the CLI calls it, with libpq_env's
  # credentials, under deadline.
  def in_process(search, deadline, env = {})
    saved = ENV.to_h
    libpq_env.merge(env).each { |name, value| value.nil? ? ENV.delete(name) : ENV.store(name, value) }
    rewrite_test.call(store: stored, options: { "search" => search }, deadline:)
  ensure
    ENV.replace(saved)
  end

  def arena_exec(sql)
    server = production.server
    conn = PG.connect(host: server.host, port: server.port, dbname: arena_name, user: TestPostgres::USER,
                      password: TestPostgres::PASSWORD)
    conn.exec(sql)
  ensure
    conn&.close
  end

  def burndown = Quaack::Enclave::Burndown.read(stored)
  def remove(entry) = FileUtils.rm_f(File.join(stored.path, "#{entry}.json"))

  # The spec_helper sets both search settings, so every fuzz record carries
  # their marks (Steps::RewriteFuzz::SETTINGS).
  def marked(extra) = extra.merge("fuzz_trials_setting" => 1, "enumerate_worlds_setting" => 1)

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
      message = lines(outcome).first
      expect(message).to include("type" => "rewrite_test", "rewrite" => "rewrite_1", "passed" => true,
                                 "scenario" => nil, "rule" => nil, "s1_load_rule" => nil)
      expect(message["s1_rows"]).to be_a(Integer).and be_positive
      expect(message["s1_nonzero_rows"]).to be_a(Integer).and be_positive
      expect(message.keys).to eq(%w[type rewrite passed scenario rule s1_load_rule s1_rows s1_nonzero_rows stage
                                    trials worlds bound])
      expect(lines(outcome).last).to eq({ "type" => "done" })
      expect(stored.read("rewrite_tested_1")).to include("passed" => true, "dropped" => 0, "s1_load_rule" => nil,
                                                         "s1_rows" => message["s1_rows"],
                                                         "s1_nonzero_rows" => message["s1_nonzero_rows"])
      expect(stored.entry?("rewrite_survived_1")).to be(false)
      expect_no_leaks(sentinels, outcome)
    end

    # Task 20261004-61: WHERE literals, a text and a number, go through
    # rewrite-test and a counterexample round to a non-empty covered and the
    # report payload's checks. Only the conditions' redacted shapes come out.
    describe "the conditions the report names (vacuity-guard)" do
      let(:query) do
        "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held' " \
          "AND o.total >= #{sentinels.number}"
      end
      let(:candidate) do
        "SELECT o.note, o.status FROM public.orders o WHERE o.status = $2 AND o.note = $1 AND o.total >= $3"
      end

      def checks = Quaack::Enclave::Steps::ReportPayload.checks(stored, "1")

      it "sends the shapes of what it left untested and what a round covered, and never a literal" do
        # No row can fail o.status = 'held' until the check goes.
        ready(candidate, status_check: "status = 'held'")
        tested = step("rewrite-test", "--search", "rewrite_1")
        expect(stored.read("rewrite_tested_1")).to include("untested" => ["o.status = $2"])
        arena_exec("ALTER TABLE public.orders DROP CONSTRAINT orders_status_check")
        covering = round(1, "INSERT INTO public.orders (id, note, status, total) VALUES (1, $1, 'open', $3)")

        expect(lines(covering).first).to include("covered" => ["o.status = $2"])
        expect(checks).to include("untested_atoms" => ["o.status = $2"], "covered" => ["o.status = $2"])
        # The query held both sentinels, so the run was exposed to them.
        expect(store.read("qualified_query")).to include(sentinels.text, sentinels.number.to_s)
        expect_no_leaks(sentinels, tested, objects: { checks:, tested: stored.read("rewrite_tested_1"),
                                                      round: stored.read("rewrite_round_1") })
        expect_no_leaks(sentinels, covering)
      end

      it "uses a check that sees a literal planted in the conditions" do
        ready(candidate, status_check: "status = 'held'")
        step("rewrite-test", "--search", "rewrite_1")
        planted = checks.merge("covered" => ["o.note = '#{sentinels.text}'", "o.total >= #{sentinels.number}"])

        expect(LeakCheck.findings(sentinels, objects: { checks: planted }).map(&:to_s)).not_to eq([])
      end
    end

    # Task 20260926-42: the report says how many scenario groups a unique
    # key left out. The near misses need the hit's note, which is unique.
    it "stores how many scenario groups it left out because they collide on a unique key" do
      ready(same, arena_sql: "CREATE UNIQUE INDEX ON public.orders (note)")

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(stored.read("rewrite_tested_1")["dropped"]).to be_positive
      expect_no_leaks(sentinels, outcome)
    end

    # Task 20261009-33: why atoms stay untested. A trigger in the arena that
    # refuses every row, with a sentinel in its message, leaves S1 unloadable:
    # the message says the rule and no row count, and never the sentinel.
    it "says S1 failed to load, by rule, without the database's message" do
      ready(same, arena_sql: <<~SQL)
        CREATE FUNCTION public.refuse() RETURNS trigger LANGUAGE plpgsql
          AS $$ BEGIN RAISE EXCEPTION '#{sentinels.text}'; END $$;
        CREATE TRIGGER refuse BEFORE INSERT ON public.orders FOR EACH ROW EXECUTE FUNCTION public.refuse();
      SQL

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(lines(outcome).first).to include("type" => "rewrite_test", "passed" => false,
                                              "s1_load_rule" => "fixture_load_failed", "s1_rows" => nil,
                                              "s1_nonzero_rows" => nil)
      expect(stored.read("rewrite_tested_1")).to include("s1_load_rule" => "fixture_load_failed", "s1_rows" => nil,
                                                         "s1_nonzero_rows" => nil)
      expect_no_leaks(sentinels, outcome)
    end

    # Task 20261012-11: a query that divides by a column production never
    # holds 0 in. The scenarios' typical values hold 0, so the original
    # fails on them, and those fixtures say nothing about the rewrite.
    describe "an original that fails on the scenarios' data" do
      let(:query) { "SELECT o.note, o.status FROM public.orders o WHERE o.status = 'held' AND (o.id / o.total) >= 2" }

      def seed(conn)
        super
        conn.exec("UPDATE public.orders SET total = total + 1; ANALYZE public.orders")
      end

      # Task 20261012-22: the fixtures the original runs on (S0, and the
      # search's, which tell its atoms apart by rows it doesn't return) show
      # none of its rows, so an equivalent rewrite was compared on nothing.
      it "finishes, leaving a rewrite compared on nothing untested, not disproved" do
        ready("SELECT o.note, o.status FROM public.orders o WHERE (o.id / o.total) >= $2 AND o.status = $1")

        outcome = step("rewrite-test", "--search", "rewrite_1")

        expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
        expect(lines(outcome).first).to include("type" => "rewrite_test", "passed" => false,
                                                "rule" => "original_failed", "scenario" => nil,
                                                "s1_load_rule" => "original_failed", "s1_rows" => nil)
        expect(stored.read("rewrite_tested_1")).to include("passed" => false, "rule" => "original_failed",
                                                           "s1_load_rule" => "original_failed")
        expect_no_leaks(sentinels, outcome)
      end

      it "disproves a wrong rewrite there" do
        ready("SELECT o.note, o.status FROM public.orders o WHERE (o.id / o.total) >= $2")

        outcome = step("rewrite-test", "--search", "rewrite_1")

        expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
        expect(lines(outcome).first).to include("type" => "rewrite_test", "passed" => false, "rule" => "row_count")
      end
    end

    # Task 20261009-40: which untested atoms the rewrite left unchanged, by
    # position, as a subset of the shapes already stored under untested.
    describe "untested_unchanged" do
      let(:held) { "status = 'held'" }

      def tested = stored.read("rewrite_tested_1")

      it "lists an untested atom of a rewrite that left it alone, and sends it on no message" do
        # No row can fail o.status = 'held', so vacuity-guard leaves it untested.
        ready(same, status_check: held)

        outcome = step("rewrite-test", "--search", "rewrite_1")

        expect(tested).to include("untested" => ["o.status = $2"], "untested_unchanged" => ["o.status = $2"])
        # The search spent its budget on it, with no difference to find.
        expect(tested).to include("untested_states" => ["searched"])
        expect(lines(outcome).first.keys).to eq(%w[type rewrite passed scenario rule s1_load_rule s1_rows
                                                   s1_nonzero_rows stage trials worlds bound])
        expect_no_leaks(sentinels, outcome)
      end

      it "leaves out an untested atom the rewrite dropped, and one it moved under a subquery" do
        ready(looser, status_check: held)
        step("rewrite-test", "--search", "rewrite_1")
        expect(tested).to include("untested" => ["o.status = $2"], "untested_unchanged" => [])

        subquery = "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND " \
                   "EXISTS (SELECT 1 FROM public.orders p WHERE p.id = o.id AND o.status = $2)"
        store.write("rewrite_1", store.read("rewrite_1").merge("sql" => subquery, "anchored_sql" => subquery))
        step("rewrite-test", "--search", "rewrite_1")
        expect(tested).to include("untested_unchanged" => [])
      end

      # Two placeholders that bind the same literal make the bound queries
      # read alike though the rewrite swapped them, so the judgment has to be
      # made on the unbound SQL.
      context "with two placeholders bound to one literal" do
        let(:query) { "SELECT #{select_list} FROM public.orders o WHERE o.note = 'held' AND o.status = 'held'" }

        it "calls an atom changed when the rewrite gave it the other placeholder" do
          swapped = "SELECT o.note, o.status FROM public.orders o WHERE o.note = $2 AND o.status = $1"
          ready(swapped, status_check: held)

          step("rewrite-test", "--search", "rewrite_1")

          expect(tested).to include("passed" => true, "untested" => ["o.status = $2"], "untested_unchanged" => [])
        end
      end

      it "stores an empty list for a discarded rewrite" do
        ready(same)
        store.write("rewrite_pruned_1", "discarded" => true)

        step("rewrite-test", "--search", "rewrite_1")

        expect(tested).to include("rule" => "discarded", "untested_unchanged" => [])
      end
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

    # Task 20260929-29: a cancel QUAACK didn't send says nothing about the
    # candidate, so the step fails and stores no verdict.
    it "fails with statement_canceled, storing no verdict, when an operator cancels the candidate" do
      ready(sleepy)

      outcome, canceled = cancel_arena_sleeper { step("rewrite-test", "--search", "rewrite_1") }

      expect(canceled).to be(true)
      expect(lines(outcome)).to eq([{ "type" => "error", "step" => "rewrite-test",
                                      "rule" => "statement_canceled", "sqlstate" => "57014" }])
      expect([stored.entry?("rewrite_tested_1"), stored.entry?("rewrite_survived_1")]).to eq([false, false])
    end

    # Task 20261008-55: rerunning the step after a foreign cancel finishes
    # it, with one verdict. public.nap sleeps only while public.naps holds a
    # row, and the canceller empties it, outside any arena transaction.
    it "succeeds on a rerun after an operator's cancel, storing one verdict" do
      ready("#{same} AND public.nap()", arena_sql: <<~SQL)
        CREATE TABLE public.naps (n int);
        INSERT INTO public.naps VALUES (1);
        CREATE FUNCTION public.nap() RETURNS boolean LANGUAGE plpgsql
          AS 'BEGIN IF EXISTS (SELECT FROM public.naps) THEN PERFORM pg_sleep(30); END IF; RETURN true; END';
      SQL

      first, canceled = cancel_arena_sleeper { step("rewrite-test", "--search", "rewrite_1") }
      arena_exec("DELETE FROM public.naps")
      second = step("rewrite-test", "--search", "rewrite_1")

      expect([canceled, lines(first).map { it["rule"] }]).to eq([true, ["statement_canceled"]])
      expect([second.stderr, second.status.exitstatus]).to eq(["", 0]), second.stdout
      expect(lines(second).map { it["type"] }.uniq).not_to include("error")
      expect(stored.read("rewrite_tested_1")).to include("passed" => true)
      expect(Dir.glob(File.join(stored.path, "rewrite_tested_*.json")).size).to eq(1)
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
                                      "scenario" => nil, "rule" => "complex_check", "stage" => "rewrite-test",
                                      "trials" => 0, "worlds" => 0, "bound" => nil }, { "type" => "done" }])
      expect(stored.read("rewrite_tested_1"))
        .to eq("passed" => false, "scenario" => nil, "rule" => "complex_check", "refused" => true,
               "stage" => "rewrite-test", "trials" => 0, "worlds" => 0, "bound" => nil,
               "untested" => [], "untested_atoms" => [], "untested_states" => [], "untested_unchanged" => [])
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
                                      "scenario" => nil, "rule" => "fk_cycle", "stage" => "rewrite-test",
                                      "trials" => 0, "worlds" => 0, "bound" => nil }, { "type" => "done" }])
      tested = stored.read("rewrite_tested_1")
      expect(tested).to include("refused" => true, "rule" => "fk_cycle",
                                "cycle" => [%w[public orders], %w[public accounts], %w[public orders]])
      expect_no_leaks(rows, outcome, objects: { tested: })
      expect_no_leaks(sentinels, outcome, objects: { tested: })
    end

    # 20261003-41: a crash between the two stored results must not leave
    # a rewrite tested but with no survival entry.
    it "stores a failed test's survival before its result, so a crash between them leaves it untested" do
      ready(looser)
      FileUtils.mkdir_p(File.join(stored.path, "rewrite_survived_1.json"))

      outcome = step("rewrite-test", "--search", "rewrite_1")

      expect(outcome.status.exitstatus).not_to eq(0)
      expect(stored.entry?("rewrite_tested_1")).to be(false)
    end

    # A refusal comes from the query, so it's recorded once per run.
    it "reuses the first refusal for a later rewrite, without connecting to the arena again" do
      ready(same, status_check: "status = 'open' OR status = 'closed'")
      step("rewrite-test", "--search", "rewrite_1")
      production.server.admin.exec(%(DROP DATABASE "#{arena_name}" WITH (FORCE)))
      store.write("rewrite_2", stored.read("rewrite_1").merge("sql" => looser, "anchored_sql" => looser))

      outcome = step("rewrite-test", "--search", "rewrite_2")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
      expect(lines(outcome)).to eq([{ "type" => "rewrite_test", "rewrite" => "rewrite_2", "passed" => false,
                                      "scenario" => nil, "rule" => "complex_check", "stage" => "rewrite-test",
                                      "trials" => 0, "worlds" => 0, "bound" => nil }, { "type" => "done" }])
      expect(stored.read("rewrite_tested_2")).to eq(stored.read("rewrite_tested_1"))
      none = { "untested_atoms" => 0, "vacuity_guard_retries" => 0 }
      expect(burndown["stages"]["rewrite-test"]["rewrite_2"]).to eq(counted(dropped: { "complex_check" => 1 },
                                                                            extra: none))
    end

    # Task 20261012-2: the fuzz search runs first, inside the rewrite's
    # budget. A lifted counterexample disproves the rewrite and ScenarioTests
    # doesn't run; a pass goes on to ScenarioTests, and stands if
    # ScenarioTests refuses the query or runs out of time.
    describe "the fuzz search before ScenarioTests" do
      def fuzz_step(search = "rewrite_1", env = FUZZ_ON) = step_with(env, search)

      def step_with(env, search)
        quaacks.run("rewrite-test", "--search", search, "--run", store.run_id, env: libpq_env.merge(env))
      end

      def tested(number = 1) = stored.read("rewrite_tested_#{number}")
      def none = { "untested_atoms" => 0, "vacuity_guard_retries" => 0 }

      it "disproves a looser rewrite with a counterexample's rule, stage, trials, and size, and no value" do
        ready(looser)

        outcome = fuzz_step("rewrite_1", FUZZ_TO_KILL)

        expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
        message = lines(outcome).first
        expect(message.keys).to eq(%w[type rewrite passed scenario rule stage trials worlds bound])
        expect(message).to include("passed" => false, "scenario" => nil, "rule" => "row_count", "stage" => "fuzz",
                                   "worlds" => 0, "bound" => nil)
        expect(message["trials"]).to be_a(Integer).and be_positive
        expect(tested).to include("passed" => false, "rule" => "row_count", "stage" => "fuzz",
                                  "trials" => message["trials"], "sizes" => [["public", "orders", 1]])
        expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
        expect(burndown["stages"]["fuzz"]["rewrite_1"])
          .to eq(counted(dropped: { "row_count" => 1 }, extra: marked("trials" => message["trials"])))
        expect(burndown["stages"].fetch("rewrite-test", {})).not_to have_key("rewrite_1")
        expect(burndown["stages"].fetch("enumerate", {})).not_to have_key("rewrite_1")
        expect_no_leaks(sentinels, outcome, objects: { tested:, burndown: })
      end

      # The query's own literals are sentinels, and fuzz offers them to
      # every compatible column, so the counterexample it lifts holds them.
      context "with sentinel literals in the query" do
        let(:query) do
          "SELECT o.note, o.status FROM public.orders o WHERE o.note = '#{sentinels.text}' AND o.status = 'held' " \
            "AND o.total >= #{sentinels.number}"
        end
        let(:candidate) { "SELECT o.note, o.status FROM public.orders o WHERE o.note = $1 AND o.total >= $3" }

        def payload_fields
          Quaack::Enclave::Steps::ReportPayload.fuzz(stored, "rewrite_1", store.read("qualified_query"), candidate)
        end

        it "disproves the rewrite and sends none of them in the message, the store entry, the burndown, or the " \
           "report's fields" do
          ready(candidate)

          # A kill needs one order with the sentinel note, a total of at
          # least the sentinel number, and a status other than held: about
          # 1 world in 20, so 40 trials missed about 1 run in 7.
          outcome = fuzz_step("rewrite_1", FUZZ_TO_KILL)

          expect(lines(outcome).first).to include("passed" => false, "stage" => "fuzz", "rule" => "row_count")
          expect(store.read("qualified_query")).to include(sentinels.text, sentinels.number.to_s)
          expect(payload_fields).to include("sizes" => [["public", "orders", 1]])
          expect_no_leaks(sentinels, outcome, objects: { tested:, burndown:, payload: payload_fields })
        end

        it "uses a check that sees a sentinel planted in the sizes" do
          planted = { "sizes" => [["public", "orders #{sentinels.text}", 1]], "trials" => sentinels.number }
          expect(LeakCheck.findings(sentinels, objects: { payload: planted }).map(&:to_s)).not_to eq([])
        end

        # The user's decision (2026-10-12): the rewrite failing on the data
        # where the original runs disproves it. Postgres's error here quotes
        # the sentinel note it couldn't read as an integer.
        it "disproves a rewrite that fails on the data where the original runs, by query_failed, and sends none " \
           "of them or the error's text" do
          failing = "#{candidate} AND CAST(o.note AS integer) IS NOT NULL"
          ready(failing)

          # Every row that reaches the cast fails it, so every kill is
          # query_failed. Only a row that matches the other conditions
          # reaches it, so this allows more worlds than the step's usual 40.
          outcome = step_with(FUZZ_TO_KILL, "rewrite_1")

          message = lines(outcome).first
          expect(message).to include("passed" => false, "stage" => "fuzz", "rule" => "query_failed")
          expect(tested).to include("rule" => "query_failed", "sizes" => [["public", "orders", 1]])
          expect(burndown["stages"]["fuzz"]["rewrite_1"])
            .to eq(counted(dropped: { "query_failed" => 1 }, extra: marked("trials" => message["trials"])))
          payload = Quaack::Enclave::Steps::ReportPayload.fuzz(stored, "rewrite_1", store.read("qualified_query"),
                                                               failing)
          expect(payload).to include("sizes" => [["public", "orders", 1]])
          expect_no_leaks(sentinels, outcome, objects: { tested:, burndown:, payload: })
        end
      end

      # Task 20261012-13: fuzz pads, case-folds and decomposes the query's
      # strings, which a needle for the whole token can miss: "ſentınel..."
      # holds no "sentinel". So a needle for the token's random hex catches
      # those too.
      context "with a sentinel the query trims" do
        let(:query) { "SELECT o.note FROM public.orders o WHERE trim(o.note) = '#{sentinels.text}'" }
        let(:candidate) { "SELECT o.note FROM public.orders o WHERE o.note = $1" }
        let(:hex) { LeakCheck::Sentinels.new(extra: { hex: sentinels.text[/\Asentinel(\h{12})/, 1] }) }

        def payload_fields
          Quaack::Enclave::Steps::ReportPayload.fuzz(stored, "rewrite_1", store.read("qualified_query"), candidate)
        end

        it "disproves the rewrite with a padded copy of it, and sends no copy of it" do
          ready(candidate)

          outcome = fuzz_step("rewrite_1", FUZZ_TO_KILL)

          expect(lines(outcome).first).to include("passed" => false, "stage" => "fuzz", "rule" => "row_count")
          expect(payload_fields).to include("sizes" => [["public", "orders", 1]])
          objects = { tested:, burndown:, payload: payload_fields }
          expect_no_leaks(sentinels, outcome, objects:)
          expect_no_leaks(hex, outcome, objects:)
        end

        it "uses a check that sees a case-folded copy planted in the sizes" do
          folded = sentinels.text.sub("s", "\u017F").sub("i", "\u0131")
          planted = { "sizes" => [["public", "orders #{folded}", 1]] }
          expect(LeakCheck.findings(sentinels, objects: { payload: planted }).map(&:to_s)).to eq([])
          expect(LeakCheck.findings(hex, objects: { payload: planted }).map(&:to_s)).not_to eq([])
        end
      end

      # Task 20261012-23: fuzz solves n / rate > 0.7 for rate, a value
      # that's in neither query: n * 10 / 7, and n / 0.8 for the rewrite.
      # Their integer parts are the needles. Neither holds the sentinel number n, so only needles for them, not
      # n's own, catch them (task 20261012-33).
      context "with a comparison whose constants solve to a sentinel" do
        let(:solutions) { [sentinels.number * 10 / 7, sentinels.number * 5 / 4].map(&:to_s) }
        let(:solved) { LeakCheck::Sentinels.new(extra: { solved: solutions[0], solved_rewrite: solutions[1] }) }
        let(:query) { "SELECT o.note FROM public.orders o WHERE #{sentinels.number} / o.rate > 0.7" }
        let(:candidate) { "SELECT o.note FROM public.orders o WHERE #{sentinels.number} / o.rate > 0.8" }

        def payload_fields
          Quaack::Enclave::Steps::ReportPayload.fuzz(stored, "rewrite_1", store.read("qualified_query"), candidate)
        end

        def seed(conn)
          super
          conn.exec("ALTER TABLE public.orders ADD COLUMN rate numeric")
        end

        it "disproves the rewrite with a value that solves its comparison, and sends none of it" do
          ready(candidate, arena_sql: "ALTER TABLE public.orders ADD COLUMN rate numeric")

          outcome = fuzz_step("rewrite_1", FUZZ_TO_KILL)

          expect(lines(outcome).first).to include("passed" => false, "stage" => "fuzz", "rule" => "row_count")
          expect(solutions).to all(satisfy { !it.include?(sentinels.number.to_s) })
          expect(payload_fields).to include("sizes" => [["public", "orders", 1]])
          objects = { tested:, burndown:, payload: payload_fields }
          expect_no_leaks(sentinels, outcome, objects:)
          expect_no_leaks(solved, outcome, objects:)
        end

        it "uses a check that sees each solution planted in the sizes, which the sentinel number's doesn't" do
          solutions.each do |solution|
            planted = { "sizes" => [["public", "orders #{solution}", 1]] }
            expect(LeakCheck.findings(sentinels, objects: { payload: planted }).map(&:to_s)).to eq([])
            expect(LeakCheck.findings(solved, objects: { payload: planted }).map(&:to_s)).not_to eq([])
          end
        end
      end

      it "goes on to ScenarioTests after a pass, which decides it, with fuzz's trials" do
        ready(same)

        message = lines(fuzz_step).first

        expect(message).to include("passed" => true, "rule" => nil, "stage" => "rewrite-test")
        expect(message["trials"]).to be_a(Integer).and be >= 40
        expect(tested).to include("passed" => true, "stage" => "rewrite-test", "trials" => message["trials"])
        expect(tested).not_to have_key("sizes")
        expect(burndown["stages"]["fuzz"]["rewrite_1"]).to eq(counted(out: 1,
                                                                      extra: marked("trials" => message["trials"])))
        expect(burndown["stages"]["rewrite-test"]["rewrite_1"]).to include("in" => 1, "out" => 1)
      end

      it "makes a rewrite whose query ScenarioTests refuses tested and passed, the first time and from the cache" do
        ready(same, status_check: "status = 'open' OR status = 'closed'")
        store.write("rewrite_2", stored.read("rewrite_1"))
        store.write("rewrite_3", stored.read("rewrite_1").merge("sql" => looser, "anchored_sql" => looser))

        outcomes = [fuzz_step("rewrite_1"), fuzz_step("rewrite_2"), fuzz_step("rewrite_3", FUZZ_TO_KILL)]

        first, second, third = outcomes.map { lines(it).first }
        [first, second].each do |message|
          expect(message).to include("passed" => true, "scenario" => nil, "rule" => nil, "stage" => "fuzz")
          expect(message["trials"]).to be_a(Integer).and be_positive
        end
        expect(stored.read("rewrite_test_refusal")).to include("refused" => true, "rule" => "complex_check")
        [1, 2].each do |number|
          expect(tested(number)).to include("passed" => true, "stage" => "fuzz")
          expect(tested(number)).not_to have_key("refused")
          expect(stored.entry?("rewrite_survived_#{number}")).to be(false)
          expect(burndown["stages"]["rewrite-test"]["rewrite_#{number}"]).to eq(counted(out: 1, extra: none))
        end
        expect(third).to include("passed" => false, "rule" => "row_count", "stage" => "fuzz")
        outcomes.each { expect_no_leaks(sentinels, it) }
      end

      # The rewrite fails on every world, but not on the data (42P01), so
      # no world is compared and nothing disproves it.
      it "leaves a refused rewrite untested when fuzz compared nothing, as without it" do
        ready("#{same} AND CAST('public.quaack_no_such_table' AS regclass) IS NOT NULL",
              status_check: "status = 'open' OR status = 'closed'")

        message = lines(fuzz_step).first

        expect(message).to eq("type" => "rewrite_test", "rewrite" => "rewrite_1", "passed" => false,
                              "scenario" => nil, "rule" => "complex_check", "stage" => "rewrite-test",
                              "trials" => 0, "worlds" => 0, "bound" => nil)
        expect(tested).to include("refused" => true, "rule" => "complex_check")
        expect(burndown["stages"]["fuzz"]["rewrite_1"]).to eq(counted(out: 1, extra: marked("trials" => 0,
                                                                                            "untested" => 1)))
      end

      # Task 20261012-15: QUAACKS_FUZZ_TRIALS and QUAACKS_ENUMERATE_WORLDS
      # are for specs, and they weaken the searches, 0 turning each off, so
      # the fuzz record, written for every rewrite tested, says when either
      # is set. A spent budget ends the search at once without them.
      it "marks the fuzz record with each search setting that's set, 0 included, and with neither when none is" do
        ready(same)
        (2..4).each { store.write("rewrite_#{it}", stored.read("rewrite_1")) }
        unset = { "QUAACKS_FUZZ_TRIALS" => nil, "QUAACKS_ENUMERATE_WORLDS" => nil }
        spent = Quaack::Enclave::Deadline.new(0)

        in_process("rewrite_1", spent, unset)
        in_process("rewrite_2", spent, unset.merge("QUAACKS_FUZZ_TRIALS" => "0"))
        in_process("rewrite_3", spent, unset.merge("QUAACKS_ENUMERATE_WORLDS" => "0"))
        in_process("rewrite_4", spent, FUZZ_ON.merge("QUAACKS_ENUMERATE_WORLDS" => "7"))

        untested = { "trials" => 0, "untested" => 1 }
        expect((1..4).map { burndown["stages"]["fuzz"]["rewrite_#{it}"]["extra"] })
          .to eq([untested, untested.merge("fuzz_trials_setting" => 1),
                  untested.merge("enumerate_worlds_setting" => 1),
                  untested.merge("fuzz_trials_setting" => 1, "enumerate_worlds_setting" => 1)])
      end

      it "runs ScenarioTests alone when QUAACKS_FUZZ_TRIALS is 0, recording fuzz as untested" do
        ready(looser)

        message = lines(step("rewrite-test", "--search", "rewrite_1")).first

        expect(message).to include("passed" => false, "scenario" => "s1", "rule" => "row_count",
                                   "stage" => "rewrite-test", "trials" => 0)
        expect(burndown["stages"]["fuzz"]["rewrite_1"]).to eq(counted(out: 1, extra: marked("trials" => 0,
                                                                                            "untested" => 1)))
      end

      # Task 20261012-34: an arena error that isn't a cancel QUAACK didn't
      # send, such as StatementCheck's refusal of a query, leaves both
      # searches untested and the rewrite to ScenarioTests.
      it "leaves both searches untested, and raises nothing, when the search fails on the arena with no foreign " \
         "cancel" do
        ready(same)
        failure = Quaack::Enclave::ArenaRunner::Error.new(:statement_not_allowed, step: :query, index: 1)
        allow(Quaack::Enclave::Fuzz).to receive(:search).and_raise(failure)

        message, = in_process("rewrite_1", Quaack::Enclave::Deadline.new, ENUMERATE_ON)

        expect(message).to include(passed: true, rule: nil, stage: "rewrite-test", trials: 0, worlds: 0, bound: nil)
        expect(burndown["stages"]["fuzz"]["rewrite_1"])
          .to eq(counted(out: 1, extra: marked("trials" => 0, "untested" => 1)))
        expect(burndown["stages"]["enumerate"]["rewrite_1"])
          .to eq(counted(out: 1, extra: { "worlds" => 0, "untested" => 1 }))
      end

      # Task 20261012-26: a cancel QUAACK didn't send, of a lift, says
      # nothing about the rewrite, so the step fails and stores nothing for
      # it, as for ScenarioTests.
      it "fails with statement_canceled, storing nothing for the rewrite, when an operator cancels fuzz's lift" do
        ready("#{looser} AND public.nap()", arena_sql: napping)

        outcome, canceled = cancel_arena_sleeper { fuzz_step("rewrite_1", FUZZ_TO_KILL) }

        expect(canceled).to be(true)
        expect(lines(outcome)).to eq([{ "type" => "error", "step" => "rewrite-test",
                                        "rule" => "statement_canceled", "sqlstate" => "57014" }])
        expect(stored_nothing?).to be(true)
      end

      # Task 20261012-34: the same for a cancel in ScenarioTests after both
      # searches passed. Fuzz and enumerate drop orders' foreign key, so
      # nap() first sleeps in ScenarioTests, and their records are stored
      # only once the rewrite's result is known.
      it "fails with statement_canceled, storing no fuzz or enumerate record either, when an operator cancels " \
         "ScenarioTests after the searches pass" do
        ready("#{same} AND public.nap()", arena_sql: napping)

        outcome, canceled = cancel_arena_sleeper { fuzz_step("rewrite_1", ENUMERATE_ON) }

        expect(canceled).to be(true)
        expect(lines(outcome)).to eq([{ "type" => "error", "step" => "rewrite-test",
                                        "rule" => "statement_canceled", "sqlstate" => "57014" }])
        expect(burndown.fetch("stages", {}).select { |_, records| records.key?("rewrite_1") }.keys).to eq([])
        expect(stored_nothing?).to be(true)
      end
    end

    # Task 20261012-3: enumerate runs after a fuzz pass, in the same
    # budget, and tries every small world over the row kinds. A lifted
    # kill disproves the rewrite by stage enumerate; a pass goes on to
    # ScenarioTests and stands, with stage enumerate, if ScenarioTests
    # refuses the query.
    describe "the enumerate stage after a fuzz pass" do
      def enumerate_step(env = ENUMERATE_ON)
        quaacks.run("rewrite-test", "--search", "rewrite_1", "--run", store.run_id, env: libpq_env.merge(env))
      end

      def tested = stored.read("rewrite_tested_1")

      # NULLS LAST matters only with a NULL created_at and a non-NULL one
      # among the rows the query keeps, which 40 random worlds miss here.
      # The search's seed is the queries' text, so the query holds no
      # sentinel, which would make it a different search each run.
      context "with a rewrite that drops NULLS LAST" do
        let(:query) do
          "SELECT o.note, o.status FROM public.orders o WHERE o.status = 'held' " \
            "ORDER BY o.created_at DESC NULLS LAST, o.id DESC LIMIT 10"
        end
        let(:candidate) do
          "SELECT o.note, o.status FROM public.orders o WHERE o.status = $1 ORDER BY o.created_at DESC, o.id DESC " \
            "LIMIT $2"
        end

        it "passes fuzz, then disproves it by stage enumerate, with trials, worlds, bound and sizes, and no value" do
          ready(candidate)

          outcome = enumerate_step

          expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
          message = lines(outcome).first
          expect(message.keys).to eq(%w[type rewrite passed scenario rule stage trials worlds bound])
          expect(message).to include("passed" => false, "scenario" => nil, "rule" => "value",
                                     "stage" => "enumerate")
          expect(message["trials"]).to be_a(Integer).and be >= 40
          expect(message["worlds"]).to be_a(Integer).and be_positive
          expect(message["bound"]).to be_a(Integer).and be_between(0, 4)
          expect(tested).to include("passed" => false, "rule" => "value", "stage" => "enumerate",
                                    "trials" => message["trials"], "worlds" => message["worlds"],
                                    "bound" => message["bound"],
                                    "sizes" => [["public", "orders", 2]])
          expect(stored.read("rewrite_survived_1")).to eq("survived" => false)
          expect(burndown["stages"]["fuzz"]["rewrite_1"])
            .to eq(counted(out: 1, extra: marked("trials" => message["trials"])))
          expect(burndown["stages"]["enumerate"]["rewrite_1"])
            .to eq(counted(dropped: { "value" => 1 }, extra: { "worlds" => message["worlds"] }))
          expect(burndown["stages"].fetch("rewrite-test", {})).not_to have_key("rewrite_1")
          fate = Quaack::Enclave::Steps::RewriteFate
          expect(fate.early(fate.steps(stored, "1"), nil)).to include("fate" => "enumerate_disproved",
                                                                      "rule" => "value")
          expect_no_leaks(sentinels, outcome, objects: { tested:, burndown: })
        end

        it "leaves it to ScenarioTests, which misses it too, when enumerate is off, recording enumerate as untested" do
          ready(candidate)

          message = lines(enumerate_step(FUZZ_ON)).first

          expect(message).to include("passed" => true, "stage" => "rewrite-test", "worlds" => 0, "bound" => nil)
          expect(message["trials"]).to be_a(Integer).and be >= 40
          expect(burndown["stages"]["enumerate"]["rewrite_1"])
            .to eq(counted(out: 1, extra: { "worlds" => 0, "untested" => 1 }))
        end

        # Task 20261012-26: as for fuzz's lift. Fuzz misses the dropped
        # NULLS LAST, so enumerate's kill is the first lift.
        it "fails with statement_canceled, storing nothing for the rewrite, when an operator cancels " \
           "enumerate's lift" do
          ready(candidate.sub("$1 ORDER", "$1 AND public.nap() ORDER"), arena_sql: napping)

          outcome, canceled = cancel_arena_sleeper { enumerate_step }

          expect(canceled).to be(true)
          expect(lines(outcome)).to eq([{ "type" => "error", "step" => "rewrite-test",
                                          "rule" => "statement_canceled", "sqlstate" => "57014" }])
          expect(stored_nothing?).to be(true)
        end
      end

      it "goes on to ScenarioTests after a pass, which decides it, with fuzz's trials and enumerate's counts" do
        ready(same)

        message = lines(enumerate_step).first

        expect(message).to include("passed" => true, "rule" => nil, "stage" => "rewrite-test")
        expect(message["trials"]).to be_a(Integer).and be >= 40
        expect(message["worlds"]).to be_a(Integer).and be_positive
        expect(message["bound"]).to be_a(Integer).and be_between(1, 4)
        expect(tested).to include("stage" => "rewrite-test", "worlds" => message["worlds"],
                                  "bound" => message["bound"])
        expect(burndown["stages"]["enumerate"]["rewrite_1"])
          .to eq(counted(out: 1, extra: { "worlds" => message["worlds"], "bound_#{message["bound"]}" => 1 }))
        expect(burndown["stages"]["rewrite-test"]["rewrite_1"]).to include("in" => 1, "out" => 1)
      end

      it "makes a rewrite whose query ScenarioTests refuses tested and passed by stage enumerate" do
        ready(same, status_check: "status = 'open' OR status = 'closed'")

        message = lines(enumerate_step).first

        expect(message).to include("passed" => true, "scenario" => nil, "rule" => nil, "stage" => "enumerate")
        expect(message["trials"]).to be_a(Integer).and be >= 40
        expect(message["bound"]).to be_a(Integer).and be_between(1, 4)
        expect(tested).to include("passed" => true, "stage" => "enumerate", "bound" => message["bound"])
        expect(tested).not_to have_key("refused")
        expect(stored.entry?("rewrite_survived_1")).to be(false)
      end

      # Task 20261012-26: an error in enumerate after a fuzz pass leaves
      # that pass standing, so it still covers a query ScenarioTests refuses.
      it "lets a fuzz pass stand for a refused query when enumerate fails, recording enumerate as untested" do
        ready(same, status_check: "status = 'open' OR status = 'closed'")
        allow(Quaack::Enclave::Fuzz::Enumerate::Kinds).to receive(:new).and_raise(Quaack::Enclave::Fuzz::Error)

        message, = in_process("rewrite_1", Quaack::Enclave::Deadline.new, ENUMERATE_ON)

        expect(message).to include(passed: true, scenario: nil, rule: nil, stage: "fuzz", worlds: 0, bound: nil)
        expect(message[:trials]).to be_a(Integer).and be >= 40
        expect(tested).to include("passed" => true, "stage" => "fuzz", "trials" => message[:trials])
        expect(burndown["stages"]["fuzz"]["rewrite_1"])
          .to eq(counted(out: 1, extra: marked("trials" => message[:trials])))
        expect(burndown["stages"]["enumerate"]["rewrite_1"])
          .to eq(counted(out: 1, extra: { "worlds" => 0, "untested" => 1 }))
      end
    end

    # Task 20261010-53: a rewrite whose test runs past its budget is
    # stopped, and the next rewrite is tested. Task 20261011-15: it isn't
    # disproved, so it goes on to counterexamples and the later stages like
    # one that passed, with rule out_of_time as its caution.
    describe "the budget per rewrite" do
      def spent = Quaack::Enclave::Deadline.new(0)

      it "carries a rewrite out of time on to counterexamples with its caution, calls it no bug, and tests the next" do
        ready(same)
        store.write("rewrite_1", stored.read("rewrite_1").merge("source" => "rule", "rules" => ["key_in_self_join"]))
        store.write("rewrite_2", stored.read("rewrite_1"))

        messages = in_process("rewrite_1", spent)

        expect(messages).to eq([{ type: :rewrite_test, rewrite: "rewrite_1", passed: true, scenario: nil,
                                  rule: "out_of_time", stage: "rewrite-test", trials: 0, worlds: 0, bound: nil }])
        line = Quaack::Enclave::Egress.serialize(messages.first)
        expect(JSON.parse(line)).to include("passed" => true, "rule" => "out_of_time")
        expect(stored.read("rewrite_tested_1")).to include("passed" => true, "rule" => "out_of_time",
                                                           "untested" => [])
        expect(stored.read("rewrite_tested_1")).not_to have_key("refused")
        expect(stored.entry?("rewrite_survived_1")).to be(false)
        expect(stored.entry?("rewrite_test_refusal")).to be(false)
        fate = Quaack::Enclave::Steps::RewriteFate
        expect(fate.early(fate.steps(stored, "1"), nil)).to be_nil
        old = { "tested" => { "passed" => false, "scenario" => nil, "rule" => "out_of_time" } }
        expect(fate.early(old, nil)).to include("fate" => "rewrite_test_out_of_time")
        expect(Quaack::Enclave::Steps::RuleBugs.call(stored)).to eq([])
        expect(burndown["stages"]["rewrite-test"]["rewrite_1"])
          .to eq(counted(out: 1, extra: { "untested_atoms" => 0, "vacuity_guard_retries" => 0,
                                          "not_tested_in_time" => 1 }))
        expect_no_leaks(sentinels, stdout: line, stderr: JSON.generate(stored.read("rewrite_tested_1")))

        expect(lines(round(1)).first).to include("type" => "counterexample_round")

        outcome = step("rewrite-test", "--search", "rewrite_2")
        expect(lines(outcome).first).to include("rewrite" => "rewrite_2", "passed" => true, "rule" => nil)
      end

      # Task 20261012-2: fuzz finished its search, so its pass stands; only
      # a budget that ran out before fuzz compared anything leaves the
      # rewrite out of time.
      it "lets a fuzz pass stand when ScenarioTests runs out of time after it, but not a budget spent before it" do
        ready(same)
        store.write("rewrite_2", stored.read("rewrite_1"))
        after_fuzz = Quaack::Enclave::Deadline.new(
          1, clock: -> { caller_locations.any? { it.path.end_with?("/scenario_tests.rb") } ? 1_000.0 : 0.0 }
        )

        passed, = in_process("rewrite_1", after_fuzz, FUZZ_ON)
        spent_first, = in_process("rewrite_2", spent, FUZZ_ON)

        expect(passed).to include(passed: true, scenario: nil, rule: nil, stage: "fuzz")
        expect(passed[:trials]).to be_a(Integer).and be >= 40
        expect(burndown["stages"]["rewrite-test"]["rewrite_1"])
          .to eq(counted(out: 1, extra: { "untested_atoms" => 0, "vacuity_guard_retries" => 0 }))
        expect(spent_first).to include(passed: true, rule: "out_of_time", stage: "rewrite-test", trials: 0)
      end

      # Task 20261012-15: a kill the budget cuts off while fuzz lifts it is
      # likely a counterexample, so fuzz claims no pass, and the rewrite
      # goes on out of time, with its caution.
      it "leaves a rewrite out of time, with no trials, when the budget runs out while fuzz lifts a kill" do
        ready(looser)
        expired = false
        lifting = Quaack::Enclave::Deadline.new(1, clock: lambda do
          expired ||= caller_locations.any? { it.path.end_with?("fuzz/lift.rb") }
          expired ? 1_000.0 : 0.0
        end)

        messages = in_process("rewrite_1", lifting, FUZZ_TO_KILL)

        expect(expired).to be(true)
        expect(messages).to eq([{ type: :rewrite_test, rewrite: "rewrite_1", passed: true, scenario: nil,
                                  rule: "out_of_time", stage: "rewrite-test", trials: 0, worlds: 0, bound: nil }])
        expect(burndown["stages"]["fuzz"]["rewrite_1"]).to eq(counted(out: 1, extra: marked("trials" => 0,
                                                                                            "untested" => 1)))
        expect(burndown["stages"]["rewrite-test"]["rewrite_1"]["extra"]).to include("not_tested_in_time" => 1)
      end

      it "leaves the arena with no row and no session open after a rewrite runs out of time partway" do
        ready(same)
        calls = 0
        partway = Quaack::Enclave::Deadline.new(1, clock: -> { (calls += 1) > 40 ? 1_000.0 : 0.0 })

        expect(in_process("rewrite_1", partway).first).to include(rule: "out_of_time")
        expect(calls).to be > 40
        expect(arena_exec("SELECT count(*) FROM public.orders").getvalue(0, 0)).to eq("0")
        expect(arena_exec("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() " \
                          "AND pid <> pg_backend_pid()").getvalue(0, 0)).to eq("0")
      end
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
        "fuzz" => { "rewrite_1" => counted(out: 1, extra: marked("trials" => 0, "untested" => 1)) },
        "enumerate" => { "rewrite_1" => counted(out: 1, extra: { "worlds" => 0, "untested" => 1 }) },
        "rewrite-test" => { "rewrite_1" => counted(out: 1, extra: { "untested_atoms" => 1,
                                                                    "vacuity_guard_retries" => 3 }) }
      )
      # A load that repeats an earlier one isn't run (20261008-33), but each comparison counts as
      # its three load orders however many it runs (20261010-47).
      expect(burndown["totals"]).to eq("fixture_loads" => 25)
    end

    it "drops a disproved rewrite by its scenario, and an untested one by the refusal's rule" do
      ready(looser)
      test
      expect(burndown["stages"]["rewrite-test"]).to eq("rewrite_1" => counted(dropped: { "s1" => 1 }, extra: none))

      production.server.admin.exec(%(DROP DATABASE "#{arena_name}" WITH (FORCE)))
      make_arena("status = 'open' OR status = 'closed'")
      store.write("rewrite_2", stored.read("rewrite_1").merge("sql" => same, "anchored_sql" => same))
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
      store.write("rewrite_1", stored.read("rewrite_1").merge("sql" => same, "anchored_sql" => same))

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
      ) } }, "totals" => { "fixture_loads" => 7 })
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
      ) } }, "totals" => { "fixture_loads" => 10 })
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
      store.write("rewrite_1", stored.read("rewrite_1").merge("sql" => same, "anchored_sql" => same))

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

    # Task 20261008-26: no reply can cover a USING or NATURAL JOIN marker, so
    # asking the LLM to exercise it wastes a round's aim.
    it "leaves out the USING and NATURAL JOIN markers no insert can cover" do
      ready(same)
      store.write("rewrite_tested_1", "passed" => true, "untested" => ["NATURAL JOIN", "o.status = $2", "USING (id)"],
                                      "untested_atoms" => [0, 1, 2])

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
        .to eq("round" => 1, "evidence" => true, "rule" => "row_count", "covered" => [], "fixture_loads" => 4)
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

    # Task 20260929-29: a cancel QUAACK didn't send isn't a disproof.
    it "fails with statement_canceled, storing no round or verdict, when an operator cancels the candidate" do
      ready(sleepy)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      outcome, canceled = cancel_arena_sleeper do
        round(1, "INSERT INTO public.orders (id, note, status) VALUES (1, $1, 'open')")
      end

      expect(canceled).to be(true)
      expect(lines(outcome)).to eq([{ "type" => "error", "step" => "counterexample-round",
                                      "rule" => "statement_canceled", "sqlstate" => "57014" }])
      expect([stored.entry?("rewrite_round_1"), stored.entry?("rewrite_survived_1")]).to eq([false, false])
    end

    it "decides survival only after a matching third round" do
      ready(same)
      store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

      expect(lines(round(1, note_row)).first).to include("match" => true)
      expect(stored.entry?("rewrite_survived_1")).to be(false)
      expect(stored.read("rewrite_round_1"))
        .to eq("round" => 1, "evidence" => true, "rule" => nil, "covered" => [], "fixture_loads" => 4)
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

    # Task 20261012-10: the rows make the original divide by zero, so the
    # round disproves nothing, and the next one runs.
    describe "a round whose rows make the original fail" do
      let(:select_list) { "o.note, (o.id / (o.total - o.id))::text" }
      let(:ratio) { "SELECT #{select_list} FROM public.orders o WHERE o.status = $2 AND o.note = $1" }

      it "reports original_failed, not a disproof, records no evidence, and runs the next round" do
        ready(ratio)
        store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])

        outcome = round(1, "INSERT INTO public.orders (id, note, status, total) VALUES (1, $1, $2, 1)")

        expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0])
        expect(lines(outcome).first).to eq("type" => "counterexample_round", "match" => nil,
                                           "rule" => "original_failed", "load_order" => nil, "covered" => [],
                                           "refused" => [], "load_failed" => false)
        expect(stored.read("rewrite_round_1")).to include("round" => 1, "evidence" => false,
                                                          "rule" => "original_failed")
        expect(stored.entry?("rewrite_survived_1")).to be(false)
        expect(burndown).to eq("stages" => {}, "totals" => {})
        expect_no_leaks(sentinels, outcome)

        second = round(2, "INSERT INTO public.orders (id, note, status, total) VALUES (1, $1, $2, 3)")

        expect(lines(second).first).to include("match" => true, "rule" => nil, "load_failed" => false)
        expect(stored.read("rewrite_round_1")).to include("round" => 2, "evidence" => true)
      end
    end

    # Task 20261012-2: a fuzz pass tests a rewrite whose query ScenarioTests
    # refuses, so its rounds run on a query rewrite-test built no atoms for.
    # They need none: it left no untested atom to cover.
    it "runs a round for a rewrite fuzz passed on a query ScenarioTests refused as complex_check" do
      ready(looser, status_check: "status = 'open' OR status = 'closed'")
      store.write("rewrite_tested_1", "passed" => true, "stage" => "fuzz", "untested" => [], "untested_atoms" => [])

      outcome = round(1, note_row)

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0]), outcome.stdout
      expect(lines(outcome).first).to include("match" => false, "rule" => "row_count", "load_failed" => false,
                                              "covered" => [])
      expect_no_leaks(sentinels, outcome)
    end

    it "fails to load inserts that need a parent row on a table whose CHECK rewrite-test refuses, by complex_check" do
      ready(looser, arena_sql: "CREATE TABLE public.customers (id int PRIMARY KEY, lo int, hi int CHECK (hi >= lo));
                                ALTER TABLE public.orders ADD customer_id int REFERENCES public.customers")
      store.write("rewrite_tested_1", "passed" => true, "stage" => "fuzz", "untested" => [], "untested_atoms" => [])

      outcome = round(1, "INSERT INTO public.orders (id, note, status, customer_id) VALUES (1, $1, 'open', 7)")

      expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0]), outcome.stdout
      expect(lines(outcome).first).to include("match" => nil, "rule" => "complex_check", "load_failed" => true)
      expect(stored.entry?("rewrite_survived_1")).to be(false)
      expect_no_leaks(sentinels, outcome)
    end

    # A fuzz pass also tests a rewrite whose query's tables reach a NOT NULL
    # foreign key cycle, which no insert can load into: each round's
    # inserts fail to load, by fk_cycle, which disproves nothing. The round
    # never names the cycle, and never has a row of the tables'.
    context "when the arena's foreign keys make a NOT NULL cycle" do
      let(:rows) { LeakCheck::Sentinels.new }

      def cycle_ready(subset)
        ready(same, arena_sql: cycle_sql(rows))
        store.write("schema_subset", "tables" => subset, "ddl" => "CREATE TABLE public.orders (id int);")
        store.write("rewrite_tested_1", "passed" => true, "untested_atoms" => [])
      end

      it "fails to load the round's inserts, by fk_cycle, even when the cycle's tables are in the schema subset" do
        cycle_ready([%w[public orders], %w[public accounts]])

        outcome = round(1, note_row)

        expect([outcome.stderr, outcome.status.exitstatus]).to eq(["", 0]), outcome.stdout
        expect(lines(outcome).first).to eq("type" => "counterexample_round", "match" => nil, "rule" => "fk_cycle",
                                           "load_order" => nil, "covered" => [], "refused" => [],
                                           "load_failed" => true)
        expect(stored.read("rewrite_round_1")).to include("evidence" => false, "rule" => "fk_cycle")
        expect_no_leaks(rows, outcome)
        expect_no_leaks(sentinels, outcome)
      end
    end
  end
end
