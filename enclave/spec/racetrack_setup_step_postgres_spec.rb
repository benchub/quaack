# frozen_string_literal: true

require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks racetrack-setup` (DESIGN.md's racetrack-setup) the way the jump server runs it: the
# installed quaacks in its own process, outside Bundler, connecting to the
# run server recorded by run-server with the operator's libpq setup. The
# stand-in production database from ProductionServer is the racetrack, as
# in run_server_postgres_spec.rb, and it holds the sentinels.
RSpec.describe "quaacks racetrack-setup, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:store) { Quaack::Enclave::Store.create(base: quaacks.store_base) }

  after do
    quaacks.remove
    production.drop
  end

  before { store.write("clock_anchor", "2026-09-23T22:15:00.123456Z") }

  def record_run_server
    store.write("run_server", "host" => production.host, "port" => production.port,
                              "racetrack_db" => production.name, "arena_db" => "quaack_arena_not_made_yet")
  end

  # Every libpq variable this process has is unset, so only what a test
  # passes is used.
  def libpq_env(**vars) = ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge(vars.transform_keys(&:to_s))

  def racetrack_setup(env: { PGUSER: production.user, PGPASSWORD: production.password })
    quaacks.run("racetrack-setup", "--run", store.run_id, env: libpq_env(**env))
  end

  def error_line(rule) = %({"type":"error","step":"racetrack-setup","rule":"#{rule}"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def racetrack_value(sql)
    conn = production.connect
    conn.exec(sql).getvalue(0, 0)
  ensure
    conn&.close
  end

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(stored.entry?("racetrack_setup")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  it "sets up the recorded racetrack, stores the marker, and prints only the done line" do
    record_run_server
    # ProductionServer makes it, so drop it to see setup make it.
    conn = production.connect
    conn.exec("DROP EXTENSION hypopg")
    conn.close

    outcome = racetrack_setup

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(racetrack_value("SELECT quaack.clock_anchor() = '2026-09-23T22:15:00.123456Z'")).to eq("t")
    expect(racetrack_value("SELECT count(*) FROM pg_extension WHERE extname = 'hypopg'")).to eq("1")
    expect(stored.read("racetrack_setup")).to be(true)
    expect_no_leaks(sentinels, outcome)
  end

  it "refuses a run with a run_server but no clock_anchor entry as missing_clock_anchor" do
    record_run_server
    File.delete(File.join(store.path, "clock_anchor.json"))

    expect_failed(racetrack_setup, "missing_clock_anchor")
  end

  it "refuses a run with no run_server entry, before connecting" do
    expect_failed(racetrack_setup(env: {}), "racetrack_setup_no_run_server")
  end

  it "fails a quaack schema it didn't make with only the rule, storing no marker" do
    record_run_server
    conn = production.connect
    conn.exec("CREATE SCHEMA quaack; CREATE TABLE quaack.#{sentinels.word} (v text)")
    conn.close

    expect_failed(racetrack_setup, "racetrack_quaack_schema_foreign")
  end

  it "fails bad credentials as run_server_connection_failed, with nothing from libpq" do
    record_run_server

    expect_failed(racetrack_setup(env: { PGUSER: sentinels.word, PGPASSWORD: sentinels.text }),
                  "run_server_connection_failed")
  end
end
