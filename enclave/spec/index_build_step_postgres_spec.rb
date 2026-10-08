# frozen_string_literal: true

require_relative "support/index_search_run"
require "quaack/enclave/index_build"
require "quaack/enclave/burndown"
require "quaack/enclave/error_filter"
require "timeout"
require_relative "support/catalog_shadow"

# DESIGN.md's index-build: `quaacks index-build` builds every distinct index from the
# index-search and rewrite-index-ideas rankings and the set-aside GIN/GiST/SP-GiST candidates,
# records sizes, and hides them. IndexBuild.show_only unhides one
# combination and confirms with a plain EXPLAIN that the rest are hidden.
RSpec.describe "quaacks index-build, against a real server" do
  include_context "an index search run"

  let(:spgist) do
    Quaack::Enclave::IndexStore.candidate_plain(
      Quaack::Enclave::IndexCandidate.new(table: orders, key: ["note"], access_method: :spgist, sources: [:t])
    )
  end

  def run(step, *extra, stdin: nil) = quaacks.run(step, "--run", store.run_id, *extra, stdin:, env: libpq_env)

  def ranked_run
    prepare
    run("index-search")
    entry = store.read("index_search_original")
    entry["dedupe"]["set_aside"] = [spgist]
    store.write("index_search_original", entry)
    run("index-rank")
  end

  def indexes(conn)
    conn.exec(<<~SQL).to_a
      SELECT c.relname, c.oid::int AS oid, i.indisvalid FROM pg_index i
      JOIN pg_class c ON c.oid = i.indexrelid WHERE i.indrelid = 'public.orders'::regclass ORDER BY c.relname
    SQL
  end

  it "builds each distinct ranked and set-aside index once, records sizes, hides only its own, sends only done" do
    ranked_run

    outcome = run("index-build")

    lines = outcome.stdout.lines
    expect([lines.last, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(lines[0...-1].map { JSON.parse(it)["type"] }).to all(eq("index_build_progress"))
    expect_no_leaks(sentinels, outcome)
    build = stored.read("index_build")
    ranking = stored.read("index_ranking_original")
    ddls = (ranking["top"] + [ranking["combination"]].compact).flat_map { it["ddl"] }.uniq +
           ["CREATE INDEX ON public.orders USING spgist (note)"]
    expect(build["indexes"].values.map { it["ddl"] }).to match_array(ddls)
    expect(build["indexes"].values.map { it["size"] }).to all(be_positive)
    expect(build["combinations"].keys).to include("original:top:1", "original:set_aside:1")
    expect(build["combinations"]["original:top:1"].map { build["indexes"][it]["ddl"] })
      .to eq(ranking["top"].first["ddl"])
    conn = production.connect
    rows = indexes(conn)
    ours = rows.select { build["indexes"].key?(it["relname"]) }
    expect(ours.size).to eq(ddls.size)
    expect(ours.map { it["indisvalid"] }).to all(eq("f"))
    expect(rows.reject { build["indexes"].key?(it["relname"]) }.map { it["indisvalid"] }).to eq(["t"])

    again = run("index-build")

    expect(again.stdout.lines.last).to eq(%({"type":"done"}\n))
    expect(indexes(conn)).to eq(rows)
  ensure
    conn&.close
  end

  # Each index's progress line carries its DDL through
  # CandidateDdlRedaction, never the stored DDL with its literals.
  # rewrite-index-ideas runs in the driver, ahead of index-build, which
  # records it: the rewrites that reached it all go on to measurement.
  it "records rewrite-index-ideas' rewrites and the indexes it built in the burndown, once when rerun" do
    ranked_run
    [true, false].each.with_index(1) do |survived, n|
      store.write("rewrite_#{n}", "sql" => "SELECT #{n}")
      store.write("rewrite_survived_#{n}", "survived" => survived)
    end

    before = Quaack::Enclave::Burndown.read(stored)
    run("index-build")
    first = Quaack::Enclave::Burndown.read(stored)
    FileUtils.rm_f(File.join(stored.path, "index_build.json"))
    run("index-build")

    expect(stored.read("index_build")["indexes"].size).to be > 1
    went_on = { "in" => 1, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => 1, "extra" => {} }
    built = stored.read("index_build")["indexes"].size
    expect(first).to eq("stages" => before["stages"].merge("rewrite-index-ideas" => { "rewrites" => went_on }),
                        "totals" => before["totals"].merge("indexes_built" => built))
    expect(Quaack::Enclave::Burndown.read(stored)).to eq(first)
  end

  it "sends a progress line before building each index, with its name and redacted DDL, never a literal" do
    ranked_run
    predicate = "note = '#{sentinels.text}'"
    planted = Quaack::Enclave::IndexCandidate.new(table: orders, key: ["total"], predicate:, sources: [:parse])
    entry = store.read("index_search_original")
    entry["set_aside"] = [Quaack::Enclave::IndexStore.candidate_plain(planted)]
    store.write("index_search_original", entry)

    outcome = run("index-build")

    lines = outcome.stdout.lines.map { JSON.parse(it) }
    build = stored.read("index_build")
    expect(build["indexes"].values.map { it["ddl"] }).to include(planted.to_ddl)
    expect(planted.to_ddl).to include(sentinels.text)
    expect(lines.last).to eq("type" => "done")
    progress = lines[0...-1]
    total = build["indexes"].size
    expect(progress.map { it.values_at("type", "index", "total") })
      .to eq((1..total).map { ["index_build_progress", it, total] })
    name = build["combinations"]["original:set_aside:2"].first
    expect(progress.map { it["ddl"] })
      .to include("CREATE INDEX #{name} ON public.orders USING btree (total) WHERE note = ?")
    expect(progress.map { it["ddl"] }).to all(start_with("CREATE INDEX quaack_"))
    expect_no_leaks(sentinels, outcome)
  end

  def progress_lines(outcome) = outcome.stdout.lines[0...-1].map { JSON.parse(it) }

  # 20261006-21: the combination often holds the top entry's index, and a
  # set-aside candidate can repeat. Each DDL is built and counted once.
  it "builds and counts once a DDL that's in several combinations" do
    ranked_run
    ranking = store.read("index_ranking_original")
    ranking["combination"] = { "ddl" => ranking["top"].first["ddl"] + ranking["top"].last["ddl"] }
    store.write("index_ranking_original", ranking)
    entry = store.read("index_search_original")
    entry["dedupe"]["set_aside"] = [spgist, spgist]
    store.write("index_search_original", entry)
    distinct = Quaack::Enclave::IndexBuild.combinations(stored).values.flatten
    expect(distinct.size - distinct.uniq.size).to be >= 2

    progress = progress_lines(run("index-build"))

    total = distinct.uniq.size
    expect(progress.map { it.values_at("index", "total") }).to eq((1..total).map { [it, total] })
    expect(progress.map { it["ddl"] }.uniq.size).to eq(total)
    build = stored.read("index_build")
    expect(build["indexes"].size).to eq(total)
    expect(build["combinations"].values_at("original:set_aside:1", "original:set_aside:2").uniq.size).to eq(1)
    expect(Quaack::Enclave::Burndown.read(stored)["totals"]["indexes_built"]).to eq(total)
  end

  def oids(conn) = indexes(conn).select { it["relname"].start_with?("quaack_") }.to_h { [it["relname"], it["oid"]] }

  # 20261004-11: the driver builds one index per call, so each gets its own
  # timeout, then makes a plain call that finds them all built.
  it "builds only the index --index names, sends its one progress line, and writes nothing else" do
    ranked_run
    total = Quaack::Enclave::IndexBuild.combinations(stored).values.flatten.uniq.size
    burndown = Quaack::Enclave::Burndown.read(stored)
    conn = production.connect

    outcome = run("index-build", "--index", "2")

    expect([outcome.stdout.lines.last, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(progress_lines(outcome).map { it.values_at("type", "index", "total") })
      .to eq([["index_build_progress", 2, total]])
    expect(progress_lines(outcome).first["ddl"]).to start_with("CREATE INDEX quaack_")
    expect(oids(conn).size).to eq(1)
    expect(stored.entry?("index_build")).to be(false)
    expect(Quaack::Enclave::Burndown.read(stored)).to eq(burndown)
  ensure
    conn&.close
  end

  it "sends nothing and builds nothing for an --index past the last index" do
    ranked_run
    total = Quaack::Enclave::IndexBuild.combinations(stored).values.flatten.uniq.size
    conn = production.connect

    outcome = run("index-build", "--index", (total + 1).to_s)

    expect(outcome.stdout).to eq(%({"type":"done"}\n))
    expect(oids(conn)).to eq({})
  ensure
    conn&.close
  end

  it "refuses an --index that isn't a positive whole number" do
    ranked_run

    expect(%w[0 -1 x 1.5].map { run("index-build", "--index", it).stdout })
      .to all(eq(%({"type":"error","step":"index-build","rule":"index_build_bad_index"}\n)))
  end

  # A resumed run: the indexes an earlier call built are on the racetrack,
  # so they're skipped, not built again and not failures.
  it "skips indexes already built, by one-index calls or an earlier run, and records them all" do
    ranked_run
    total = Quaack::Enclave::IndexBuild.combinations(stored).values.flatten.uniq.size
    conn = production.connect
    run("index-build", "--index", "1")
    first = oids(conn)

    again = run("index-build", "--index", "1")
    (2..total).each { run("index-build", "--index", it.to_s) }
    built = oids(conn)
    final = run("index-build")

    expect([again.stdout.lines.last, final.stdout.lines.last]).to eq([%({"type":"done"}\n)] * 2)
    expect(built.slice(*first.keys)).to eq(first)
    expect(built.size).to eq(total)
    expect(oids(conn)).to eq(built)
    expect(stored.read("index_build")["indexes"].keys).to match_array(built.keys)
    expect(stored.read("index_build")["indexes"].values.map { it["size"] }).to all(be_positive)
    expect(indexes(conn).select { built.key?(it["relname"]) }.map { it["indisvalid"] }).to all(eq("f"))
  ensure
    conn&.close
  end

  # 20261004-12: every index on one table is built before the next table's,
  # while the first is still in cache. Tables go in the order they first
  # appear; within a table, the order is the one they arrived in.
  context "with candidates on two tables that arrive interleaved" do
    let(:items) { Quaack::Enclave::TableName.new(schema: "public", name: "items") }

    def candidate(table, key) = Quaack::Enclave::IndexCandidate.new(table:, key: [key], sources: [:parse])

    def interleaved_run
      ranked_run
      conn = production.connect
      conn.exec("CREATE TABLE public.items (a int, b int); INSERT INTO public.items VALUES (1, 1), (2, 2)")
      set_aside(candidate(items, "a"), candidate(orders, "total"), candidate(items, "b"))
    ensure
      conn&.close
    end

    def set_aside(*planted)
      entry = store.read("index_search_original")
      entry["set_aside"] = planted.map { Quaack::Enclave::IndexStore.candidate_plain(it) }
      store.write("index_search_original", entry)
    end

    def table(ddl) = ddl[/ ON (\S+) /, 1]
    def names(lines) = lines.map { it["ddl"][/\ACREATE INDEX (\S+) /, 1] }

    it "builds them grouped by table, both one per call and in a plain call, and builds and reports them all" do
      interleaved_run
      arrived = Quaack::Enclave::IndexBuild.combinations(stored).values.flatten.uniq
      expect(arrived.map { table(it) }.slice_when { |a, b| a != b }.count).to be > 2
      grouped = arrived.partition { table(it) == "public.orders" }.flatten.map { Quaack::Enclave::IndexBuild.name(it) }

      one_by_one = (1..arrived.size).flat_map { progress_lines(run("index-build", "--index", it.to_s)) }
      plain = progress_lines(run("index-build"))

      expect(names(plain)).to eq(grouped)
      expect(plain.map { it["index"] }).to eq((1..arrived.size).to_a)
      expect(one_by_one).to eq(plain)
      build = stored.read("index_build")
      expect(build["indexes"].keys).to match_array(grouped)
      expect(build["indexes"].values.map { it["size"] }).to all(be_positive)
    end
  end

  it "builds the unused low-cardinality B-tree candidates index-test set aside (20260927-11)" do
    ranked_run
    btree = Quaack::Enclave::IndexCandidate.new(table: orders, key: %w[status total], sources: [:parse])
    entry = store.read("index_search_original")
    entry["set_aside"] = [Quaack::Enclave::IndexStore.candidate_plain(btree)]
    store.write("index_search_original", entry)

    expect(run("index-build").stdout.lines.last).to eq(%({"type":"done"}\n))

    build = stored.read("index_build")
    expect(build["combinations"]["original:set_aside:2"].map { build["indexes"][it]["ddl"] }).to eq([btree.to_ddl])
    expect(build["indexes"][build["combinations"]["original:set_aside:2"].first]["size"]).to be_positive
  end

  it "unhides just one combination, confirms it with EXPLAIN, and catches a hidden index the plan uses" do
    ranked_run
    run("index-build")
    build = stored.read("index_build")
    conn = production.connect
    names = build["combinations"]["original:set_aside:1"]
    sql = "SELECT note FROM public.orders WHERE note = 'n7'"
    conn.exec("SET enable_seqscan = off; SET enable_bitmapscan = off")

    used = Quaack::Enclave::IndexBuild.show_only(conn, build, "original:set_aside:1", sql:)

    expect(used).to eq(names)
    valid = indexes(conn).select { build["indexes"].key?(it["relname"]) }.to_h { [it["relname"], it["indisvalid"]] }
    expect(valid).to eq(build["indexes"].keys.to_h { [it, names.include?(it) ? "t" : "f"] })
    conn.exec("UPDATE pg_index SET indisvalid = false WHERE indexrelid = 'public.#{names.first}'::regclass")
    other = (build["indexes"].keys - names).first
    conn.exec("UPDATE pg_index SET indisvalid = true WHERE indexrelid = 'public.#{other}'::regclass")
    expect { Quaack::Enclave::IndexBuild.confirm(conn, build, [], sql:) }
      .to raise_error(Quaack::Enclave::IndexBuild::Error, "index_build_hidden_index_used")
  ensure
    conn&.close
  end

  it "never hides a primary key, a user unique index even named quaack_, or a user index not named quaack_" do
    prepare
    conn = production.connect
    conn.exec("CREATE UNIQUE INDEX quaack_x ON public.orders (id, note)")
    conn.exec("CREATE INDEX user_note ON public.orders (note)")
    pkey = conn.exec("SELECT conname FROM pg_constraint WHERE conrelid = 'public.orders'::regclass AND contype = 'p'")
               .getvalue(0, 0)

    Quaack::Enclave::IndexBuild.set_valid(conn, ["quaack_x", pkey, "user_note"], false, schemas: "public")

    expect(indexes(conn).select { %W[quaack_x #{pkey} user_note].include?(it["relname"]) }.map { it["indisvalid"] })
      .to eq(%w[t t t])
    conn.exec("CREATE INDEX quaack_y ON public.orders (note)")
    Quaack::Enclave::IndexBuild.set_valid(conn, ["quaack_y"], false, schemas: "public")
    expect(indexes(conn).find { it["relname"] == "quaack_y" }["indisvalid"]).to eq("f")
  ensure
    conn&.close
  end

  it "hides and reads validity by schema and name, leaving a same-named index in another schema alone" do
    prepare
    conn = production.connect
    conn.exec("CREATE SCHEMA other; CREATE TABLE other.orders (note text)")
    conn.exec("CREATE INDEX quaack_y ON public.orders (note); CREATE INDEX quaack_y ON other.orders (note)")

    Quaack::Enclave::IndexBuild.set_valid(conn, ["quaack_y"], false, schemas: "public")

    other = conn.exec("SELECT indisvalid FROM pg_index WHERE indexrelid = 'other.quaack_y'::regclass").getvalue(0, 0)
    expect(other).to eq("t")
    build = { "indexes" => { "quaack_y" => { "ddl" => "CREATE INDEX ON public.orders (note)" } } }
    expect(Quaack::Enclave::IndexBuild.valid_names(conn, build)).to eq([])
  ensure
    conn&.close
  end

  it "refuses unqualified DDL" do
    prepare
    conn = production.connect
    expect { Quaack::Enclave::IndexBuild.create(conn, "quaack_z", "CREATE INDEX ON orders (note)") }
      .to raise_error(Quaack::Enclave::IndexBuild::Error, "index_build_unqualified")
  ensure
    conn&.close
  end

  it "builds with raised maintenance settings" do
    ranked_run
    conn = production.connect
    Quaack::Enclave::IndexBuild.build(store, conn)

    expect(conn.exec("SHOW maintenance_work_mem").getvalue(0, 0)).to eq("1GB")
    expect(conn.exec("SHOW max_parallel_maintenance_workers").getvalue(0, 0)).to eq("4")
  ensure
    conn&.close
  end

  # Task 20260930-14: the build connection's search_path puts public ahead
  # of pg_catalog, and public's comparisons say no (see CatalogShadow).
  # The catalog reads and the indisvalid update still find QUAACK's index.
  context "when public's comparison operators shadow pg_catalog's" do
    let(:ddl) { "CREATE INDEX ON public.orders (note)" }
    let(:name) { Quaack::Enclave::IndexBuild.name(ddl) }

    it "builds, sizes, hides, and shows the index, and finds it built on a second call" do
      conn = production.connect
      seed(conn)
      CatalogShadow.plant(conn, :operators)
      conn.exec("SET search_path = public, pg_catalog")
      build = { "indexes" => { name => { "ddl" => ddl } } }
      index_build = Quaack::Enclave::IndexBuild

      size = index_build.create(conn, name, ddl)
      expect([size, index_build.create(conn, name, ddl)]).to eq([size, size])
      expect(size).to be_positive
      index_build.hide_all(conn, build)
      hidden = index_build.valid_names(conn, build)
      index_build.set_valid(conn, [name], true, schemas: "public")

      expect([hidden, index_build.valid_names(conn, build)]).to eq([[], [name]])
    ensure
      conn&.close
    end
  end

  # 20261006-9: a build whose client was killed, as the driver's timeout
  # kills ssh, while its CREATE INDEX waits on a lock another session holds.
  context "with an orphaned build of the same index" do
    let(:ddl) { "CREATE INDEX ON public.orders (note)" }
    let(:name) { Quaack::Enclave::IndexBuild.name(ddl) }

    def builders(conn)
      conn.exec_params(<<~SQL, ["CREATE INDEX #{name} %"]).column_values(0).map(&:to_i)
        SELECT pid FROM pg_stat_activity WHERE state = 'active' AND query LIKE $1
      SQL
    end

    def wait_for(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      yield
    end

    # builder builds ARGV's index from its own process, after
    # BuildConnection.configure unless ARGV's last is "false". Without
    # configure, the server doesn't check for a lost client, as before
    # Postgres 14.
    let(:builder) do
      <<~RUBY
        require "pg"
        require "quaack/enclave/index_build"
        host, port, dbname, user, password, name, ddl, configure = ARGV
        c = PG.connect(host:, port:, dbname:, user:, password:)
        Quaack::Enclave::BuildConnection.configure(c) unless configure == "false"
        Quaack::Enclave::IndexBuild.create(c, name, ddl)
      RUBY
    end
    let(:server) { [production.host, production.port.to_s, production.name, production.user, production.password] }

    def spawn_builder(configure)
      Process.spawn(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", builder,
                    *server, name, ddl, configure.to_s)
    end

    # Starts builder, waits until its backend is running the build, kills
    # it, and returns the backend's pid.
    def orphan(conn, configure: true)
      child = spawn_builder(configure)
      wait_for(10) { builders(conn).any? }
      Process.kill(:KILL, child)
      Process.wait(child)
      builders(conn).first
    end

    def build_in_thread
      Thread.new do
        c = production.connect
        Quaack::Enclave::BuildConnection.configure(c)
        Quaack::Enclave::IndexBuild.create(c, name, ddl)
      ensure
        c&.close
      end
    end

    # @locker holds the lock. @monitor watches from outside its
    # transaction, since pg_stat_activity holds still within one.
    before do
      @locker = production.connect
      @monitor = production.connect
      seed(@locker)
      @locker.exec("BEGIN; LOCK TABLE public.orders IN ACCESS EXCLUSIVE MODE")
    end

    after do
      @locker&.close
      @monitor&.close
    end

    # Task 20260930-14: public's <> and LIKE, ahead of pg_catalog's on the
    # resume's search_path, would find no orphan.
    it "cancels the orphan when public's comparison operators shadow pg_catalog's" do
      CatalogShadow.plant(@monitor, :operators)
      orphaned = orphan(@monitor, configure: false)
      resume = Thread.new do
        c = production.connect
        c.exec("SET search_path = public, pg_catalog")
        Quaack::Enclave::IndexBuild.create(c, name, ddl)
      ensure
        c&.close
      end
      cancelled = wait_for(5) { !builders(@monitor).include?(orphaned) }
      @locker.exec("COMMIT")

      expect(cancelled).to be(true)
      expect(resume.value).to be_positive
    end

    it "cancels the orphan before building, so a resume builds it without a duplicate name" do
      orphaned = orphan(@monitor, configure: false)
      expect(orphaned).to be_a(Integer)
      resume = build_in_thread
      cancelled = wait_for(5) { !builders(@monitor).include?(orphaned) }
      @locker.exec("COMMIT")

      expect(cancelled).to be(true)

      expect(resume.value).to be_positive
      count = @monitor.exec_params("SELECT count(*) FROM pg_class WHERE relname = $1", [name]).getvalue(0, 0)
      expect(count).to eq("1")
    end

    # 20261006-15: a role that can see the orphan's query (pg_read_all_stats)
    # but can't signal it, since a superuser owns it.
    context "when the build role can't signal the orphan" do
      let(:watcher) { "watcher_#{SecureRandom.hex(6)}" }

      before do
        production.server.admin.exec(<<~SQL)
          CREATE ROLE #{watcher} LOGIN PASSWORD '#{production.password}' IN ROLE pg_read_all_stats, pg_signal_backend
        SQL
      end

      after do
        @watching&.close
        production.server.admin.exec("DROP ROLE IF EXISTS #{watcher}")
      end

      it "refuses as index_build_orphan_cancel_denied, with no raw error, and leaves the orphan running" do
        orphaned = orphan(@monitor, configure: false)
        @watching = PG.connect(host: production.host, port: production.port, dbname: production.name,
                               user: watcher, password: production.password)

        error = begin
          Quaack::Enclave::BuildConnection.cancel_orphans(@watching, name)
        rescue StandardError => e
          e
        end

        expect(error).to an_instance_of(Quaack::Enclave::IndexBuild::Error)
          .and(having_attributes(message: "index_build_orphan_cancel_denied", cause: nil))
        expect(JSON.parse(Quaack::Enclave::ErrorFilter.to_egress(error, step: "index-build")))
          .to eq("type" => "error", "step" => "index-build", "rule" => "index_build_orphan_cancel_denied")
        expect([orphaned.class, builders(@monitor).include?(orphaned)]).to eq([Integer, true])

        # Ends the orphan here, so it can't build once after closes the
        # locker (20261006-25).
        @monitor.exec_params("SELECT pg_terminate_backend($1)", [orphaned])
        expect(wait_for(5) { !builders(@monitor).include?(orphaned) }).to be(true)
      end
    end

    it "sets client_connection_check_interval, so the server ends the orphan soon after its client is gone" do
      conn = production.connect
      Quaack::Enclave::BuildConnection.configure(conn)
      expect(conn.exec("SHOW client_connection_check_interval").getvalue(0, 0)).to eq("2s")
      orphaned = orphan(@monitor)

      gone = wait_for(8) { !builders(@monitor).include?(orphaned) }

      expect([orphaned.class, gone]).to eq([Integer, true])
    ensure
      conn&.close
    end
  end

  # 20261006-15: backends that match the orphan's name but that the cancel
  # mustn't wait out forever, or touch at all.
  context "with a backend the cancel can't stop, or one that's idle" do
    def wait_for(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      sleep 0.05 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      yield
    end

    def activity(conn, pid)
      conn.exec_params("SELECT state, wait_event, query FROM pg_stat_activity WHERE pid = $1", [pid]).first
    end

    before do
      @admin = production.connect
      seed(@admin)
    end

    after do
      @admin.exec_params("SELECT pg_terminate_backend($1)", [@stubborn.backend_pid]) if @stubborn
      @stubborn&.close
      @admin&.close
    end

    # A function that swallows the first %<cancels>d cancels, then sleeps on,
    # unguarded, so the next one stops it, as a backend stuck where
    # pg_cancel_backend doesn't take effect would. Each statement start is
    # a point where a cancel takes effect, so the whole wait sits inside the
    # handler's block, not just each sleep. Only a cancel that lands while
    # the handler runs, just after the one it caught, could slip through,
    # and cancel_orphans spaces them 0.1 s apart (20261007-1).
    let(:stubborn_function) do
      <<~SQL
        CREATE FUNCTION public.stubborn(int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
        DECLARE caught int := 0;
        BEGIN
          WHILE caught < %<cancels>d LOOP
            BEGIN
              LOOP PERFORM pg_sleep(0.05); END LOOP;
            EXCEPTION WHEN query_canceled THEN caught := caught + 1;
            END;
          END LOOP;
          PERFORM pg_sleep(60);
          RETURN $1;
        END $$
      SQL
    end

    # Starts building an index on stubborn, and returns the index's name
    # and the backend's pid once the backend is sleeping in the function,
    # not merely active: until then, a cancel stops the build outright.
    def stubborn(cancels)
      @admin.exec(format(stubborn_function, cancels:))
      name = Quaack::Enclave::IndexBuild.name("CREATE INDEX ON public.orders ((public.stubborn(id)))")
      @stubborn = production.connect
      pid = @stubborn.backend_pid
      @stubborn.send_query("CREATE INDEX #{name} ON public.orders ((public.stubborn(id)))")
      sleeping = wait_for(10) { activity(@admin, pid)&.values_at("state", "wait_event") == %w[active PgSleep] }
      expect(sleeping).to be(true)
      [name, pid]
    end

    it "refuses index_build_orphan_running once the wait is up, if the orphan won't stop" do
      name, pid = stubborn(1_000_000)
      conn = production.connect
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      # Timeout caps the call, so a broken deadline fails here, not hangs
      # on a backend that never stops (20261007-4).
      expect { Timeout.timeout(30) { Quaack::Enclave::BuildConnection.cancel_orphans(conn, name, wait: 1) } }
        .to raise_error(Quaack::Enclave::IndexBuild::Error, "index_build_orphan_running")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be_between(1, 5)
      expect(activity(@admin, pid)["state"]).to eq("active")
    ensure
      conn&.close
    end

    # 20261006-25: the backend outlasts three rounds of cancels, so it's
    # cancelled four times but returned once.
    it "returns the orphans it cancelled, once each, though it cancelled them more than once" do
      name, pid = stubborn(3)
      conn = production.connect

      expect(Quaack::Enclave::BuildConnection.cancel_orphans(conn, name)).to eq([pid])
      expect(activity(@admin, pid)["state"]).not_to eq("active")
    ensure
      conn&.close
    end

    it "leaves alone an idle connection whose last query built the same index" do
      name = Quaack::Enclave::IndexBuild.name("CREATE INDEX ON public.orders (note)")
      idle = production.connect
      idle.exec("CREATE INDEX #{name} ON public.orders (note)")
      conn = production.connect

      expect(activity(@admin, idle.backend_pid).values_at("state", "query"))
        .to eq(["idle", "CREATE INDEX #{name} ON public.orders (note)"])
      expect(Quaack::Enclave::BuildConnection.cancel_orphans(conn, name, wait: 1)).to eq([])
    ensure
      idle&.close
      conn&.close
    end
  end
end
