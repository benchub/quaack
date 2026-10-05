# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "shellwords"
require "quaack/enclave/inventory/production"
require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks run-server` (DESIGN.md's run-server) the way the jump server runs it: the
# installed quaacks in its own process, outside Bundler, connecting with the
# operator's libpq setup in a temporary HOME. The stand-in production
# database from ProductionServer is production and the racetrack both, as
# in run_server_check_postgres_spec.rb: inventory's inventory is read from it,
# and then the step checks it as the run server. Arena isn't connected to
# at this step, since arena-setup makes it, so its name needn't exist yet.
RSpec.describe "quaacks run-server, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:store) { Quaack::Enclave::Store.create(base: quaacks.store_base) }
  let(:arena_db) { "quaack_arena_not_made_yet" }

  after do
    quaacks.remove
    production.drop
  end

  def pgpass(user: production.user, password: production.password, port: production.port)
    path = File.join(quaacks.home, ".pgpass")
    File.write(path, "*:#{port}:*:#{user}:#{password}\n")
    File.chmod(0o600, path)
  end

  # Every libpq variable this process has is unset, so only the operator's
  # setup a test builds is used.
  def libpq_env(**vars) = ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge(vars.transform_keys(&:to_s))

  # Stores production's inventory the way inventory does, after the block, if
  # any, changes it.
  def record_inventory
    conn = production.connect
    inventory = Quaack::Enclave::Inventory::Production.read(conn, plan_settings: %w[search_path work_mem])
    conn.close
    yield inventory if block_given?
    store.write("inventory", inventory)
  end

  def run_server(host: production.host, port: production.port.to_s, racetrack: production.name, arena: arena_db,
                 env: { PGUSER: production.user })
    quaacks.run("run-server", "--run", store.run_id, "--host", host, "--port", port, "--racetrack-db", racetrack,
                "--arena-db", arena, env: libpq_env(**env))
  end

  # The run server must have no other clients (DESIGN.md's racetrack-setup), so every
  # connection this process holds, including the harness's own and any a
  # spec left open, is ended first.
  def close_every_harness_connection
    TestPostgres.server.admin.exec(<<~SQL)
      SELECT pg_terminate_backend(pid, 5000) FROM pg_stat_activity
      WHERE backend_type = 'client backend' AND pid <> pg_backend_pid()
    SQL
    TestPostgres.server.close_admin
  end

  def done = %({"type":"done"}\n)
  def error_line(rule) = %({"type":"error","step":"run-server","rule":"#{rule}"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(stored.entry?("run_server")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  describe "the subcommand" do
    it "records a run server that passes every check, and prints only the done line" do
      record_inventory
      pgpass
      # A connection another spec in this process left open.
      production.connect
      close_every_harness_connection

      outcome = run_server

      expect(outcome.stdout).to eq(done), outcome.stdout
      expect(outcome.stderr).to eq("")
      expect(outcome.status.exitstatus).to eq(0)
      expect(stored.read("run_server")).to eq("host" => production.host, "port" => production.port,
                                              "racetrack_db" => production.name, "arena_db" => arena_db)
      expect_no_leaks(sentinels, outcome)
    end

    # PgBouncer in session mode in front of the run server reports a pid of
    # its own to libpq, not the server backend's (DESIGN.md's run-server).
    it "records a run server behind PgBouncer in session mode" do
      bouncer_port = TestPostgres.server.pgbouncer_port
      record_inventory
      pgpass(port: bouncer_port)
      close_every_harness_connection

      outcome = run_server(port: bouncer_port.to_s)

      expect(outcome.stdout).to eq(done), outcome.stdout
      expect(outcome.stderr).to eq("")
      expect(outcome.status.exitstatus).to eq(0)
      expect(stored.read("run_server")).to eq("host" => production.host, "port" => bouncer_port,
                                              "racetrack_db" => production.name, "arena_db" => arena_db)
      expect_no_leaks(sentinels, outcome)
    end

    it "aborts on another client, naming only the check and the client's pid and start time, and records nothing" do
      record_inventory
      pgpass
      close_every_harness_connection
      app_name = "sentinel-app-#{SecureRandom.hex(6)}"
      other = production.connect
      begin
        other.exec("SET application_name = '#{app_name}'")
        # Its start time, read apart from the check: its epoch's whole
        # seconds, as UTC.
        epoch = other.exec("SELECT floor(extract(epoch FROM backend_start))::bigint FROM pg_stat_activity " \
                           "WHERE pid = pg_backend_pid()").getvalue(0, 0)
        clients = [{ "pid" => other.backend_pid,
                     "backend_start" => Time.at(Integer(epoch, 10)).utc.strftime("%Y-%m-%dT%H:%M:%SZ") }]
        outcome = run_server
      ensure
        other.close
      end

      expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus])
        .to eq([%(#{JSON.generate("type" => "error", "step" => "run-server", "rule" => "run_server_other_clients",
                                  "clients" => clients)}\n), "", 70])
      expect(outcome.stdout).not_to include(app_name)
      expect(stored.entry?("run_server")).to be(false)
      expect_no_leaks(sentinels, outcome)
    end

    it "aborts on a planner setting that isn't production's, without its name or value" do
      record_inventory
      pgpass
      TestPostgres.server.admin.exec(%(ALTER DATABASE "#{production.name}" SET search_path = public))

      expect_failed(run_server, "run_server_guc_mismatch")
    end

    # The postgres database, on the same server, lacks the hypopg extension
    # production has.
    it "checks the racetrack database it's given" do
      record_inventory
      pgpass

      expect_failed(run_server(racetrack: "postgres"), "run_server_extension_missing")
    end

    it "fails a bad password as run_server_connection_failed, naming neither the host nor the user" do
      record_inventory
      pgpass(user: sentinels.word, password: sentinels.text)

      outcome = run_server(env: { PGUSER: sentinels.word })

      expect_failed(outcome, "run_server_connection_failed")
      expect(outcome.stdout).not_to include(production.host)
    end

    it "refuses a run with no inventory as run_server_no_inventory, before connecting" do
      # No libpq setup at all, so a connection attempt would fail differently.
      expect_failed(run_server(env: {}), "run_server_no_inventory")
    end

    it "refuses a bad argument without echoing it, before connecting" do
      record_inventory

      expect_failed(run_server(host: "#{sentinels.word} x"), "bad_run_server_host")
      expect_failed(run_server(port: "0"), "bad_run_server_port")
      expect_failed(run_server(port: "54\xff32"), "bad_run_server_port")
      expect_failed(run_server(arena: "#{sentinels.word};"), "bad_run_server_database")
    end

    describe "with run_server_command in the quaacks config" do
      def configure(command)
        FileUtils.mkdir_p(File.join(quaacks.home, ".quaack"))
        File.write(File.join(quaacks.home, ".quaack", "config.json"), JSON.generate("run_server_command" => command))
      end

      def printing(object) = "printf '%s' #{Shellwords.escape(JSON.generate(object))}"

      def made = { host: production.host, port: production.port, racetrack_db: production.name, arena_db: }

      def run_bare(*flags)
        quaacks.run("run-server", "--run", store.run_id, *flags,
                    env: libpq_env(PGUSER: production.user))
      end

      before do
        store.write("server", "prod 1")
        record_inventory
        pgpass
        TestPostgres.server.close_admin
      end

      it "records the run server the command prints, given the server and the run" do
        args = File.join(quaacks.home, "args")
        configure("printf '%s|%s' {server} {run} > #{args}; #{printing(made)}")

        expect(run_bare.stdout).to eq(done)
        expect(File.read(args)).to eq("prod 1|#{store.run_id}")
        expect(stored.read("run_server")).to eq(made.transform_keys(&:to_s))
      end

      it "lets a flag override what the command prints" do
        configure(printing(made.merge(racetrack_db: "postgres")))

        expect(run_bare("--racetrack-db", production.name).stdout).to eq(done)
        expect(stored.read("run_server")["racetrack_db"]).to eq(production.name)
      end

      it "fails a failing command as run_server_command_failed, without its output" do
        configure("echo #{sentinels.word}; exit 1")

        expect_failed(run_bare, "run_server_command_failed")
      end
    end

    it "refuses a call missing an option as usage" do
      outcome = quaacks.run("run-server", "--run", store.run_id, "--host", production.host, "--port", "5432",
                            "--racetrack-db", production.name, env: libpq_env)

      expect(outcome.stdout).to eq(error_line("usage"))
      expect(outcome.status.exitstatus).to eq(64)
    end
  end

  # RunServer.connect, which later racetrack and arena steps use, in the
  # installed gem's own process.
  describe "RunServer.connect" do
    def connect_in_child(script, **env)
      quaacks.run_ruby(<<~RUBY, store.run_id, quaacks.store_base, env: libpq_env(**env))
        require "quaack/enclave/run_server"
        require "quaack/enclave/store"
        store = Quaack::Enclave::Store.open(ARGV[0], base: ARGV[1])
        #{script}
      RUBY
    end

    before do
      store.write("run_server", "host" => production.host, "port" => production.port,
                                "racetrack_db" => production.name, "arena_db" => "postgres")
    end

    it "connects to the recorded racetrack or arena database with the operator's credentials, dropping notices" do
      outcome = connect_in_child(<<~RUBY, PGUSER: production.user, PGPASSWORD: production.password)
        %i[racetrack arena].each do |database|
          conn = Quaack::Enclave::RunServer.connect(store, database)
          conn.exec("DO $$ BEGIN RAISE NOTICE '%', #{sentinels.text.inspect.tr('"', "'")}; END $$")
          print conn.exec("SELECT current_database()").getvalue(0, 0), " "
          conn.close
        end
      RUBY

      expect(outcome.stdout).to eq("#{production.name} postgres ")
      expect(outcome.stderr).to eq("")
      expect(outcome.status.exitstatus).to eq(0)
    end

    it "raises run_server_connection_failed with nothing from libpq" do
      outcome = connect_in_child(<<~RUBY, PGUSER: sentinels.word, PGPASSWORD: sentinels.text)
        begin
          Quaack::Enclave::RunServer.connect(store, :arena)
        rescue Quaack::Enclave::RunServer::Error => e
          print [e.rule, e.message, e.cause.inspect].join(" ")
        end
      RUBY

      expect(outcome.stdout).to eq("run_server_connection_failed run_server_connection_failed nil")
      expect_no_leaks(sentinels, outcome)
    end
  end
end
