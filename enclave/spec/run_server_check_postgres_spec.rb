# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"
require "quaack/enclave/run_server_check"
require "quaack/enclave/error_filter"
require "quaack/enclave/inventory/production"
require "quaack/enclave/store"
require_relative "support/production_server"

# Step 4's run server checks (DESIGN.md, step 4). The stand-in production
# database from ProductionServer is production and the run server both:
# its inventory is read from it, then the check runs on a new connection
# to it, which matches until an example changes one thing.
# What the plan's SETTINGS would list for ProductionServer, whose database
# sets both.
RUN_SERVER_PLAN_SETTINGS = %w[search_path work_mem].freeze

RSpec.describe Quaack::Enclave::RunServerCheck do
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:base) { Dir.mktmpdir }
  let(:store) { Quaack::Enclave::Store.create(base:) }
  let(:connections) { [] }

  after do
    connections.each(&:close)
    production.drop
    FileUtils.rm_rf(base)
  end

  def connect = production.connect.tap { connections << it }
  def run_server = @run_server ||= connect

  # Reads production's inventory the way step 2 does and stores it, after
  # the block, if any, changes it.
  def record_inventory(plan_settings: RUN_SERVER_PLAN_SETTINGS)
    conn = production.connect
    inventory = Quaack::Enclave::Inventory::Production.read(conn, plan_settings:)
    conn.close
    yield inventory if block_given?
    store.write("inventory", inventory)
  end

  # The harness's own connection to the server is its, not another client.
  def run_check(connection = run_server, own_connections: [TestPostgres.server.admin])
    described_class.run(store:, connection:, own_connections:)
  end

  def failure(...)
    run_check(...)
    nil
  rescue Quaack::Enclave::RunServerCheck::Error => e
    e
  end

  def expect_failure(rule, name)
    error = failure
    expect(error).not_to be_nil, "expected #{rule}, and every check passed"
    expect([error.rule, error.message]).to eq([rule, "#{rule}: #{name}"])
  end

  def alter_database(setting) = TestPostgres.server.admin.exec(%(ALTER DATABASE "#{production.name}" SET #{setting}))

  it "passes a run server that matches production's inventory" do
    record_inventory

    expect(run_check).to be_nil
  end

  it "reports only the first failure, in the order the checks run" do
    record_inventory { it["database"]["datctype"] = "other" }
    run_server.exec("SET enable_seqscan = off")

    expect_failure("run_server_locale_mismatch", "datctype")
  end

  describe "access" do
    it "fails a role that isn't a superuser" do
      record_inventory
      role = "quaack_not_super_#{SecureRandom.hex(4)}"
      TestPostgres.server.admin.exec("CREATE ROLE #{role} NOLOGIN")
      run_server.exec("SET ROLE #{role}")

      expect_failure("run_server_not_superuser", "is_superuser")
    ensure
      run_server.exec("RESET ROLE")
      TestPostgres.server.admin.exec("DROP ROLE IF EXISTS #{role}")
    end
  end

  describe "major version and extensions" do
    it "fails a major version that isn't production's" do
      record_inventory { it["major_version"] = 17 }

      expect_failure("run_server_major_version", "server_version_num")
    end

    it "fails when an extension production has isn't installed" do
      record_inventory
      run_server.exec("DROP EXTENSION hypopg")

      expect_failure("run_server_extension_missing", "hypopg")
    end

    it "fails when an extension's version isn't production's" do
      record_inventory { it["extensions"]["hypopg"] = "0.9" }

      expect_failure("run_server_extension_version", "hypopg")
    end

    # Production needn't have HypoPG, and 4a creates it, so it's enough
    # that the run server can.
    it "passes HypoPG that isn't installed but is available" do
      record_inventory { it["extensions"].delete("hypopg") }
      run_server.exec("DROP EXTENSION hypopg")

      expect(run_check).to be_nil
    end

    it "fails when HypoPG is neither installed nor available" do
      record_inventory { it["extensions"].delete("hypopg") }
      run_server.exec("DROP EXTENSION hypopg")
      run_server.exec("SET extension_control_path = '/nonexistent'")

      expect_failure("run_server_hypopg_missing", "hypopg")
    end
  end

  describe "locale" do
    %w[datcollate datctype datlocprovider datlocale datcollversion].each do |field|
      it "fails when pg_database's #{field} isn't production's" do
        record_inventory { it["database"][field] = "#{it["database"][field]}x" }

        expect_failure("run_server_locale_mismatch", field)
      end
    end

    it "fails when default_text_search_config isn't production's" do
      record_inventory
      run_server.exec("SET default_text_search_config = 'pg_catalog.english'")

      expect_failure("run_server_locale_mismatch", "default_text_search_config")
    end

    # The racetrack is restored under a name of the operator's choosing.
    it "passes a database whose name isn't production's" do
      record_inventory { it["database"]["datname"] = "other" }

      expect(run_check).to be_nil
    end
  end

  describe "planner settings" do
    # EXPLAIN SETTINGS lists only what differs from the built-in default,
    # so one it doesn't list ran at the default.
    it "fails a setting the plan's SETTINGS doesn't list that isn't at its built-in default" do
      record_inventory
      run_server.exec("SET enable_seqscan = off")

      expect_failure("run_server_guc_mismatch", "enable_seqscan")
    end

    it "fails the developer setting debug_parallel_query when it isn't at its default" do
      record_inventory
      run_server.exec("SET debug_parallel_query = on")

      expect_failure("run_server_guc_mismatch", "debug_parallel_query")
    end

    it "takes production's value of a setting the plan's SETTINGS lists, and fails another value" do
      alter_database("enable_hashjoin = off")
      record_inventory(plan_settings: [*RUN_SERVER_PLAN_SETTINGS, "enable_hashjoin"])

      expect(run_check).to be_nil

      run_server.exec("SET enable_hashjoin = on")
      expect_failure("run_server_guc_mismatch", "enable_hashjoin")
    end

    it "fails a setting the plan's SETTINGS lists that production has and the run server doesn't" do
      record_inventory(plan_settings: [*RUN_SERVER_PLAN_SETTINGS, "quaack.planner_knob"]) do |inventory|
        inventory["plan_settings"]["quaack.planner_knob"] = "on"
      end

      expect_failure("run_server_guc_mismatch", "quaack.planner_knob")
    end

    # effective_cache_size is one of step 2's settings, and
    # max_parallel_workers_per_gather one of its parallel settings.
    {
      "effective_cache_size" => %w[1GB 4GB], "max_parallel_workers_per_gather" => %w[4 2]
    }.each do |name, (production_value, other_value)|
      it "takes production's recorded #{name}, even when the plan's SETTINGS doesn't list it" do
        alter_database("#{name} = '#{production_value}'")
        record_inventory

        expect(run_check).to be_nil

        run_server.exec("SET #{name} = '#{other_value}'")
        expect_failure("run_server_guc_mismatch", name)
      end
    end

    {
      "TimeZone" => "America/New_York", "DateStyle" => "SQL, DMY", "IntervalStyle" => "iso_8601",
      "default_statistics_target" => "500"
    }.each do |name, value|
      it "fails #{name}, which SETTINGS never lists, when it isn't production's recorded value" do
        record_inventory
        run_server.exec("SET #{name} = '#{value}'")

        expect_failure("run_server_guc_mismatch", name)
      end
    end

    it "fails a planner setting SETTINGS never lists when the inventory didn't record it" do
      record_inventory { it["settings"].delete("default_statistics_target") }

      expect_failure("run_server_guc_mismatch", "default_statistics_target")
    end

    it "doesn't compare shared_buffers, which doesn't change plans" do
      record_inventory { it["settings"]["shared_buffers"] = "64GB" }

      expect(run_check).to be_nil
    end

    it "names search_path, and never its value, production's or the run server's" do
      record_inventory
      run_server.exec(%(SET search_path = "#{sentinels.word}"))
      error = failure

      expect(store.read("inventory")["plan_settings"]["search_path"]).to include(sentinels.text)
      expect([error.rule, error.message]).to eq(["run_server_guc_mismatch", "run_server_guc_mismatch: search_path"])
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "4")
      expect(line).to eq('{"type":"error","step":"4","rule":"run_server_guc_mismatch"}')
      expect_no_leaks(sentinels, stdout: line, objects: { error: })
    end
  end

  describe "quiet" do
    it "fails when another client is connected" do
      record_inventory
      connect

      expect_failure("run_server_other_clients", "pg_stat_activity")
    end

    # What a client's backend_start should read as, found apart from the
    # check: the whole seconds of its epoch, as UTC.
    def started(conn)
      epoch = TestPostgres.server.admin.exec_params(
        "SELECT floor(extract(epoch FROM backend_start))::bigint FROM pg_stat_activity WHERE pid = $1",
        [conn.backend_pid]
      ).getvalue(0, 0)
      Time.at(Integer(epoch, 10)).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def client(conn) = { "pid" => conn.backend_pid, "backend_start" => started(conn) }

    it "names each other client by its pid and start time, in UTC, oldest first, and nothing else about it" do
      # Production and the run server both show times at +05:30, so a start
      # time that isn't made UTC reads wrong.
      alter_database("TimeZone = 'Asia/Kolkata'")
      record_inventory
      app_name = "sentinel-app-#{SecureRandom.hex(6)}"
      first = connect
      first.exec("SET application_name = '#{app_name}'")
      second = connect
      error = failure

      expect([error.rule, error.message])
        .to eq(["run_server_other_clients", "run_server_other_clients: pg_stat_activity"])
      expect(error.clients).to eq([client(first), client(second)])
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "4")
      expect(JSON.parse(line)).to eq("type" => "error", "step" => "4", "rule" => "run_server_other_clients",
                                     "clients" => error.clients)
      expect([line, error.message, error.clients.inspect]).to all(satisfy { !it.include?("sentinel-app") })
    end

    # pg_stat_activity lists backends by slot, not by age, once a slot an
    # older backend doesn't hold comes free. So a young client that lands in
    # an earlier slot is listed before an old one, and only the check's own
    # order can put the old one first.
    it "names the oldest other client first, whatever order pg_stat_activity lists them in" do
      record_inventory
      run_server
      old = connect
      young = connect_listed_before(old)

      expect(failure.clients.map { it["pid"] }).to eq([old.backend_pid, young.backend_pid])
    end

    # A connection opened after old that pg_stat_activity lists before it:
    # it opens and closes one until one lands in an earlier slot.
    def connect_listed_before(old, tries: 1000)
      tries.times do
        young = production.connect
        return young.tap { connections << it } if listed_before?(young, old)

        young.close
      end
      raise "no connection was listed before pid #{old.backend_pid} in #{tries} tries"
    end

    def listed_before?(young, old)
      pids = TestPostgres.server.admin.exec("SELECT pid FROM pg_stat_activity WHERE backend_type = 'client backend'")
                         .column_values(0).map { Integer(it, 10) }
      pids.index(young.backend_pid) < pids.index(old.backend_pid)
    end

    it "names at most twenty other clients, the oldest, and still fails with more" do
      record_inventory
      run_server
      others = Array.new(21) { connect }

      error = failure

      expect(error.rule).to eq("run_server_other_clients")
      expect(error.clients.map { it["pid"] }).to eq(others.first(20).map(&:backend_pid))
    end

    it "passes QUAACK's own other connections" do
      record_inventory
      other = connect

      expect(run_check(own_connections: [TestPostgres.server.admin, other])).to be_nil
    end

    # PgBouncer in session mode in front of the run server (DESIGN.md, step
    # 4): the pid libpq reports for a connection through it is one PgBouncer
    # made up, not the server backend's.
    describe "behind PgBouncer in session mode" do
      def through_pgbouncer = production.connect(port: TestPostgres.server.pgbouncer_port).tap { connections << it }

      def server_pid(conn) = Integer(conn.exec("SELECT pg_backend_pid()").getvalue(0, 0), 10)

      it "passes a quiet server, reached through PgBouncer" do
        record_inventory
        pooled = through_pgbouncer
        expect(pooled.backend_pid).not_to eq(server_pid(pooled))

        expect(run_check(pooled)).to be_nil
      end

      it "passes QUAACK's own other connections through PgBouncer" do
        record_inventory
        pooled = through_pgbouncer
        other = through_pgbouncer
        # Each has its server backend before the check looks.
        [pooled, other].each { server_pid(it) }

        expect(run_check(pooled, own_connections: [TestPostgres.server.admin, other])).to be_nil
      end

      it "fails on another client connected through PgBouncer, naming its server backend's pid" do
        record_inventory
        pooled = through_pgbouncer
        other = through_pgbouncer
        pid = server_pid(other)

        error = failure(pooled)

        expect(error.rule).to eq("run_server_other_clients")
        expect(error.clients.map { it["pid"] }).to eq([pid])
      end

      it "fails on another client connected directly" do
        record_inventory
        pooled = through_pgbouncer
        other = connect

        error = failure(pooled)

        expect(error.rule).to eq("run_server_other_clients")
        expect(error.clients.map { it["pid"] }).to eq([other.backend_pid])
      end

      # pooled takes its server backend first, or PgBouncer would hand it
      # the one gone left idle.
      it "fails on a server backend PgBouncer keeps idle in its pool after its client closed" do
        record_inventory
        pooled = through_pgbouncer
        server_pid(pooled)
        gone = production.connect(port: TestPostgres.server.pgbouncer_port)
        pid = server_pid(gone)
        gone.close

        error = failure(pooled)

        expect(error.rule).to eq("run_server_other_clients")
        expect(error.clients.map { it["pid"] }).to eq([pid])
      end
    end

    it "fails when pg_cron runs its jobs from another database, which it can't see" do
      record_inventory
      run_server.exec("SET cron.database_name = 'postgres'")

      expect_failure("run_server_cron_elsewhere", "cron.database_name")
    end

    # cron.job, the way pg_cron defines it, as far as the check reads it.
    def plant_cron_job(active:)
      run_server.exec("CREATE SCHEMA cron")
      run_server.exec("CREATE TABLE cron.job (jobid bigint, active boolean)")
      run_server.exec("INSERT INTO cron.job VALUES (1, #{active})")
      run_server.exec(%(SET cron.database_name = "#{production.name}"))
    end

    it "fails when pg_cron has an active job" do
      record_inventory
      plant_cron_job(active: true)

      expect_failure("run_server_cron_active", "cron.job")
    end

    it "passes pg_cron jobs that aren't active" do
      record_inventory
      plant_cron_job(active: false)

      expect(run_check).to be_nil
    end

    # The shared server runs with autovacuum off, and a -c setting outranks
    # ALTER SYSTEM, so this one needs a server of its own.
    it "fails when autovacuum is on" do
      extra = TestPostgres.extra_server(TestPostgres::SERVER_SETTINGS - ["autovacuum=off"])
      conn = extra.admin
      store.write("inventory", Quaack::Enclave::Inventory::Production.read(conn, plan_settings: []))

      expect(conn.exec("SHOW autovacuum").getvalue(0, 0)).to eq("on")
      error = failure(conn, own_connections: [])
      expect([error&.rule, error&.message]).to eq(["run_server_autovacuum_on", "run_server_autovacuum_on: autovacuum"])
    ensure
      TestPostgres.remove_server(extra) if extra
    end
  end

  describe "the trust boundary" do
    it "keeps the database's name, and every other value, out of its error and its error line" do
      record_inventory { it["database"]["datcollate"] = sentinels.text }
      error = failure

      expect(store.read("inventory")["database"]["datname"]).to eq(sentinels.word)
      expect(error.rule).to eq("run_server_locale_mismatch")
      line = Quaack::Enclave::ErrorFilter.to_egress(error, step: "4")
      expect(line).to eq('{"type":"error","step":"4","rule":"run_server_locale_mismatch"}')
      expect_no_leaks(sentinels, stdout: line, objects: { error: })
    end
  end
end
