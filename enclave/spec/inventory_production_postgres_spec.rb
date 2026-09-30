# frozen_string_literal: true

require "delegate"
require "quaack/enclave/inventory/production"
require_relative "support/production_server"
require_relative "support/catalog_shadow"

# What step 2 reads from production (DESIGN.md, step 2), against a stand-in
# production database on the test harness's Postgres.
RSpec.describe Quaack::Enclave::Inventory::Production do
  let(:production_module) { described_class }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }

  after do
    @conn&.close
    production.drop
  end

  def conn = @conn ||= production.connect

  def show(name) = conn.exec("SELECT current_setting($1)", [name]).getvalue(0, 0)

  def error_of
    yield
    raise "expected an Inventory::Error"
  rescue Quaack::Enclave::Inventory::Error => e
    e
  end

  # Runs the block with the libpq environment variables set as given, and
  # every other one this process has unset, then puts them back.
  def with_libpq_env(vars)
    saved = ENV.to_h
    ENV.each_key { ENV.delete(it) if it.start_with?("PG") }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    ENV.replace(saved)
  end

  def operator_env(**overrides)
    { "PGPORT" => production.port.to_s, "PGUSER" => production.user, "PGPASSWORD" => production.password,
      "PGDATABASE" => production.name, **overrides }
  end

  describe ".read" do
    let(:inventory) { production_module.read(conn, plan_settings: %w[enable_hashjoin search_path]) }

    it "records the major version and the full version number" do
      expect(inventory["server_version_num"]).to eq(Integer(show("server_version_num")))
      expect(inventory["major_version"]).to eq(Integer(show("server_version_num")) / 10_000)
      expect(inventory["major_version"]).to eq(18)
    end

    it "records the installed extensions and their versions" do
      hypopg = conn.exec("SELECT extversion FROM pg_extension WHERE extname = 'hypopg'").getvalue(0, 0)

      expect(inventory["extensions"]).to eq("hypopg" => hypopg, "plpgsql" => "1.0")
    end

    # TimeZone and the rest change plans but aren't in EXPLAIN's SETTINGS,
    # so step 4 can't tell production's value from the plan (DESIGN.md, step 2).
    it "records the memory and cost settings, and the planner settings SETTINGS never lists, as SHOW prints them" do
      expect(inventory["settings"].keys).to eq(%w[shared_buffers effective_cache_size work_mem random_page_cost jit
                                                  TimeZone DateStyle IntervalStyle default_statistics_target])
      expect(inventory["settings"]).to eq(inventory["settings"].keys.to_h { [it, show(it)] })
      expect(inventory["settings"]["work_mem"]).to eq(ProductionServer::WORK_MEM)
    end

    # Postgres 18's parallel settings, written out rather than found by a
    # query, so a name the step's own query misses shows up here. That
    # includes enable_gathermerge and max_worker_processes, which parallel
    # plans and workers depend on without "parallel" in their names.
    let(:parallel_settings) do
      %w[
        debug_parallel_query enable_gathermerge enable_parallel_append enable_parallel_hash
        max_parallel_apply_workers_per_subscription max_parallel_maintenance_workers max_parallel_workers
        max_parallel_workers_per_gather max_worker_processes min_parallel_index_scan_size
        min_parallel_table_scan_size parallel_leader_participation parallel_setup_cost parallel_tuple_cost
      ]
    end

    it "records every parallel setting, including enable_gathermerge and max_worker_processes" do
      expect(inventory["parallel_settings"].keys).to eq(parallel_settings)
      expect(inventory["parallel_settings"]).to eq(parallel_settings.to_h { [it, show(it)] })
    end

    it "records production's own value of each setting the plan's SETTINGS lists, and nil for one it lacks" do
      inventory = production_module.read(conn, plan_settings: %w[enable_hashjoin search_path quaack.no_such_setting])

      expect(inventory["plan_settings"]).to eq("enable_hashjoin" => "on", "search_path" => production.search_path,
                                               "quaack.no_such_setting" => nil)
    end

    it "records the database's locale fields from pg_database" do
      expect(inventory["database"]).to eq(
        "datname" => production.name, "datcollate" => "C", "datctype" => "C", "datlocprovider" => "b",
        "datlocale" => "C.UTF-8",
        "datcollversion" => conn.exec("SELECT datcollversion FROM pg_database WHERE datname = current_database()")
                                .getvalue(0, 0)
      )
      expect(inventory["database"]["datcollversion"]).to match(/\A\d/)
    end

    it "records default_text_search_config" do
      expect(inventory["default_text_search_config"]).to eq("public.#{production.ts_config}")
    end

    it "reads inside one read-only, repeatable read transaction, and ends it" do
      inventory = production_module.read(conn, plan_settings: %w[transaction_read_only transaction_isolation])

      expect(inventory["plan_settings"]).to eq("transaction_read_only" => "on",
                                               "transaction_isolation" => "repeatable read")
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
    end

    # A search_path that puts public before pg_catalog, and public holding
    # relations, functions, and types named like the catalog's (see
    # CatalogShadow): read still reads the catalog, so it records what it
    # did before they were planted.
    it "reads the catalog, not what a public schema shadows it with" do
      conn.exec("SET search_path = public, pg_catalog")
      plan_settings = %w[enable_hashjoin search_path]
      before = production_module.read(conn, plan_settings:)
      CatalogShadow.plant(conn)

      expect(production_module.read(conn, plan_settings:)).to eq(before)
      expect(before["extensions"]).to include("hypopg")
    end
  end

  describe ".read_only" do
    it "can't write: a write in its transaction fails with 25006, and nothing is written" do
      error = error_of { production_module.read_only(conn) { conn.exec("CREATE TABLE quaack_written ()") } }

      expect([error.rule, error.sqlstate]).to eq(%w[production_read_failed 25006])
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
      expect(conn.exec("SELECT to_regclass('quaack_written')").getvalue(0, 0)).to be_nil
    end

    it "returns the block's value" do
      expect(production_module.read_only(conn) { conn.exec("SELECT 41 + 1").getvalue(0, 0) }).to eq("42")
    end

    it "keeps Postgres's message out of its error, and keeps the SQLSTATE" do
      error = error_of { production_module.read_only(conn) { conn.exec("SELECT '#{sentinels.text}'::int") } }

      expect([error.rule, error.sqlstate]).to eq(%w[production_read_failed 22P02])
      expect(error.cause).to be_nil
      expect_no_leaks(sentinels, objects: { error: })
    end
  end

  describe ".major_version" do
    it "takes Postgres 17 and later, which have pg_database.datlocale" do
      expect(production_module.major_version(170_000)).to eq(17)
      expect(production_module.major_version(180_001)).to eq(18)
    end

    it "refuses an older server as unsupported_production_version" do
      expect(error_of { production_module.major_version(160_009) }.rule).to eq("unsupported_production_version")
    end

    # The harness runs only Postgres 18, so this real connection claims to
    # be 16 when asked its version. That's the one thing faked.
    it "is what read checks, so read refuses an older server" do
      older = Class.new(SimpleDelegator) do
        def exec(sql, ...) = sql == "SHOW server_version_num" ? __getobj__.exec("SELECT '160009'") : super
      end.new(conn)

      expect(error_of { production_module.read(older, plan_settings: []) }.rule).to eq("unsupported_production_version")
      expect(conn.transaction_status).to eq(PG::PQTRANS_IDLE)
    end
  end

  describe ".connect" do
    it "connects to the host it's given, with the rest from the operator's libpq setup" do
      connection = with_libpq_env(operator_env) { production_module.connect(production.host) }

      expect(connection.exec("SELECT current_database()").getvalue(0, 0)).to eq(production.name)
      expect(connection.host).to eq(production.host)
    ensure
      connection&.close
    end

    it "drops the connection's notices, so none reaches stderr" do
      connection = with_libpq_env(operator_env) { production_module.connect(production.host) }

      expect { connection.exec("DO $$BEGIN RAISE NOTICE '%', 'x'; END$$") }.not_to output.to_stderr_from_any_process
    ensure
      connection&.close
    end

    it "refuses a bad password or a bad host as production_connection_failed, naming neither the host nor the user" do
      s = sentinels
      bad_login = operator_env("PGUSER" => s.word, "PGPASSWORD" => s.text)
      # What libpq itself says names the user, so the check below means something.
      expect { with_libpq_env(bad_login) { PG.connect(host: production.host) } }
        .to raise_error(PG::ConnectionBad, /#{s.word}/)

      errors = [
        with_libpq_env(bad_login) { error_of { production_module.connect(production.host) } },
        with_libpq_env(operator_env("PGPORT" => "1")) { error_of { production_module.connect("127.0.0.1") } }
      ]

      expect(errors.map { [it.rule, it.sqlstate] }).to eq([["production_connection_failed", nil]] * 2)
      expect(errors.map(&:cause)).to eq([nil, nil])
      expect_no_leaks(sentinels, objects: { errors: })
    end
  end
end
