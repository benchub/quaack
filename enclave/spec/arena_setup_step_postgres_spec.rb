# frozen_string_literal: true

require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks arena-setup` (DESIGN.md's arena-setup) the way the jump server runs it: the
# installed quaacks in its own process, outside Bundler. The stand-in
# production database is the racetrack, and arena is made beside it. The
# stored dump is in the shape pg_dump 18 writes, \restrict lines and
# CREATE SCHEMA public included, and names a sentinel table.
RSpec.describe "quaacks arena-setup, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:store) { Quaack::Enclave::Store.create(base: quaacks.store_base) }
  let(:arena_db) { "quaack_arena_#{Process.pid}_#{rand(1_000_000)}" }
  let(:admin) { TestPostgres.server.admin }

  let(:dump) do
    <<~SQL
      \\restrict AbCdEf123
      SET statement_timeout = 0;
      SELECT pg_catalog.set_config('search_path', '', false);
      CREATE SCHEMA public;
      CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;
      CREATE TABLE public.customers (id bigint PRIMARY KEY, email public.citext);
      CREATE TABLE public.#{sentinels.word} (
        id bigint PRIMARY KEY,
        customer_id bigint NOT NULL REFERENCES public.customers,
        qty integer CONSTRAINT qty_positive CHECK (qty > 0)
      );
      CREATE FUNCTION public.refuse() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RAISE 'no'; END$$;
      CREATE TRIGGER refuse BEFORE INSERT ON public.#{sentinels.word} FOR EACH ROW EXECUTE FUNCTION public.refuse();
      \\unrestrict AbCdEf123
    SQL
  end

  before do
    store.write("clock_anchor", "2026-09-23T22:15:00.123456Z")
    store.write("inventory", { "database" => { "datname" => sentinels.word, "datcollate" => "C", "datctype" => "C",
                                               "datlocprovider" => "b", "datlocale" => "C.UTF-8" },
                                "settings" => { "TimeZone" => "UTC" } })
    store.write("schema_dump", { "namespaces" => ["public"], "ddl" => dump })
  end

  after do
    quaacks.remove
    admin.exec(%(DROP DATABASE IF EXISTS "#{arena_db}" WITH (FORCE)))
    production.drop
  end

  def record_run_server
    store.write("run_server", "host" => production.host, "port" => production.port,
                              "racetrack_db" => production.name, "arena_db" => arena_db)
  end

  def libpq_env(**vars) = ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge(vars.transform_keys(&:to_s))

  def arena_setup(env: { PGUSER: production.user, PGPASSWORD: production.password })
    quaacks.run("arena-setup", "--run", store.run_id, env: libpq_env(**env))
  end

  def error_line(rule) = %({"type":"error","step":"arena-setup","rule":"#{rule}"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)

  def arena_values(sql)
    conn = PG.connect(host: production.host, port: production.port, dbname: arena_db,
                      user: production.user, password: production.password)
    conn.exec(sql).values
  ensure
    conn&.close
  end

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(stored.entry?("arena_setup")).to be(false)
    expect_no_leaks(sentinels, outcome)
  end

  it "builds arena with production's locale, the dump, the clock anchor, and only user triggers disabled" do
    record_run_server

    outcome = arena_setup

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([%({"type":"done"}\n), "", 0])
    expect(stored.read("arena_setup")).to be(true)
    expect_no_leaks(sentinels, outcome)
    expect(arena_values("SELECT datlocprovider::text, datlocale, datcollate, datctype FROM pg_database " \
                        "WHERE datname = current_database()")).to eq([%w[b C.UTF-8 C C]])
    expect(arena_values("SELECT quaack.clock_anchor() = '2026-09-23T22:15:00.123456Z'")).to eq([%w[t]])
    expect(arena_values("SELECT format_type(atttypid, NULL) FROM pg_attribute " \
                        "WHERE attrelid = 'public.customers'::regclass AND attname = 'email'")).to eq([%w[citext]])
    expect(arena_values("SELECT tgname, tgenabled::text FROM pg_trigger WHERE tgrelid = " \
                        "'public.#{sentinels.word}'::regclass AND NOT tgisinternal")).to eq([%w[refuse D]])
    expect(arena_values("SELECT count(*) FROM pg_trigger WHERE tgrelid = 'public.#{sentinels.word}'::regclass " \
                        "AND tgisinternal AND tgenabled <> 'O'")).to eq([%w[0]])
    expect(arena_values("SELECT count(*) FROM pg_extension WHERE extname = 'hypopg'")).to eq([%w[0]])
  end

  {
    "libc" => [{ "datlocprovider" => "c", "datlocale" => nil }, ["c", nil, "en_US.utf8", "en_US.utf8"]],
    "ICU" => [{ "datlocprovider" => "i", "datlocale" => "en-US" }, %w[i en-US en_US.utf8 en_US.utf8]]
  }.each do |name, (entry, row)|
    it "builds arena with production's #{name} locale" do
      record_run_server
      store.write("inventory", { "database" => { "datname" => sentinels.word, "datcollate" => "en_US.utf8",
                                                 "datctype" => "en_US.utf8", **entry },
                                  "settings" => { "TimeZone" => "UTC" } })

      expect(arena_setup.stdout).to eq(%({"type":"done"}\n))
      expect(arena_values("SELECT datlocprovider::text, datlocale, datcollate, datctype FROM pg_database " \
                          "WHERE datname = current_database()"))
        .to eq([row])
    end
  end

  it "drops and rebuilds its own arena on a rerun" do
    record_run_server
    expect(arena_setup.status.exitstatus).to eq(0)
    arena_values("CREATE TABLE public.leftover (id int)")

    expect(arena_setup.status.exitstatus).to eq(0)
    expect(arena_values("SELECT to_regclass('public.leftover') IS NULL")).to eq([%w[t]])
  end

  it "refuses a database of that name it didn't make, and leaves it alone" do
    record_run_server
    admin.exec(%(CREATE DATABASE "#{arena_db}"))

    expect_failed(arena_setup, "arena_database_foreign")
    expect(arena_values("SELECT to_regclass('quaack.clock_anchor') IS NULL")).to eq([%w[t]])
  end

  it "fails a dump that won't load with only the rule" do
    record_run_server
    store.write("schema_dump", { "namespaces" => ["public"], "ddl" => "CREATE TABLE #{sentinels.word} (" })

    expect_failed(arena_setup, "arena_dump_load_failed")
  end

  it "refuses a run with no run_server entry, before connecting" do
    expect_failed(arena_setup(env: {}), "arena_setup_no_run_server")
  end
end
