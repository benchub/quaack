# frozen_string_literal: true

require "fileutils"
require "json"
require "quaack/enclave/store"
require_relative "support/production_server"

# `quaacks schema-dump --run <run ID>` (DESIGN.md 3b) the way the jump server
# runs it: the installed quaacks in its own process, outside Bundler, with
# the operator's libpq setup in a temporary HOME, as `quaacks qualify` does.
# It reads the run's server and relations entries, which qualify wrote.
#
# The jump server runs pg_dump from PATH. Here PATH starts with a directory
# holding a pg_dump that runs the harness container's own pg_dump 18 (at
# the edge, like SchemaDump's own spec), reaching the stand-in database over
# the container's own port 5432. A column default and a comment hold
# sentinels, standing in for production DDL that must stay in the enclave.
RSpec.describe "quaacks schema-dump, against a real server" do
  let(:quaacks) { LeakCheck::Quaacks.new }
  let(:sentinels) { ProductionServer.sentinels }
  let!(:production) { ProductionServer.create(sentinels) }
  let(:relations) { [{ "schema" => "sales", "name" => "items" }] }
  let(:bin) { File.join(quaacks.home, "bin") }
  let(:store) do
    Quaack::Enclave::Store.create(base: quaacks.store_base).tap do |store|
      store.write("server", production.host)
      store.write("relations", relations)
    end
  end

  before do
    conn = production.connect
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE SCHEMA audit;
      CREATE TABLE audit.vendors (id int PRIMARY KEY);
      CREATE TABLE public.orders (id int PRIMARY KEY, note text DEFAULT '#{sentinels.text}');
      CREATE TABLE sales.items (id int, order_id int REFERENCES public.orders,
                                vendor_id int REFERENCES audit.vendors);
      CREATE TABLE sales.unrelated (id int);
      COMMENT ON TABLE sales.items IS '#{sentinels.text}';
    SQL
    conn.close
    container_pg_dump
  end

  after do
    quaacks.remove
    production.drop
  end

  def pgpass(user: production.user, password: production.password)
    path = File.join(quaacks.home, ".pgpass")
    File.write(path, "*:#{production.port}:*:#{user}:#{password}\n")
    File.chmod(0o600, path)
  end

  def pg_dump_script(body)
    FileUtils.mkdir_p(bin)
    path = File.join(bin, "pg_dump")
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o700, path)
  end

  # The container's pg_dump, given the operator's libpq variables. Inside
  # the container, Postgres listens on 5432, and the password is the one
  # the operator's ~/.pgpass holds here. HOME is the temporary one, so
  # docker is pointed at the real user's config, which names its context.
  def container_pg_dump(before: "")
    pg_dump_script(<<~SH)
      export DOCKER_CONFIG='#{ENV.fetch("DOCKER_CONFIG", File.join(Dir.home, ".docker"))}'
      #{before}
      exec docker exec -e PGPORT=5432 -e PGUSER="$PGUSER" -e PGDATABASE="$PGDATABASE" \\
        -e PGPASSWORD='#{production.password}' #{TestPostgres.server.container_id} pg_dump "$@"
    SH
  end

  def libpq_env(**vars) = ENV.keys.grep(/\APG/).to_h { [it, nil] }.merge(vars.transform_keys(&:to_s))

  def operator_env(**overrides)
    { PGPORT: production.port.to_s, PGUSER: production.user, PGDATABASE: production.name,
      PATH: "#{bin}:#{ENV.fetch("PATH")}", **overrides }
  end

  def schema_dump(env: operator_env) = quaacks.run("schema-dump", "--run", store.run_id, env: libpq_env(**env))

  def done = %({"type":"done"}\n)
  def error_line(rule) = %({"type":"error","step":"schema-dump","rule":"#{rule}"}\n)
  def stored = Quaack::Enclave::Store.open(store.run_id, base: quaacks.store_base)
  def created_tables(ddl) = ddl.scan(/^CREATE TABLE (.+) \($/).flatten.sort

  def expect_failed(outcome, rule)
    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([error_line(rule), "", 70])
    expect(%w[schema_dump schema_subset].select { stored.entry?(it) }).to eq([])
    expect_no_leaks(sentinels, outcome)
  end

  it "stores the dump of the query's namespaces and public, and the subset with its FK parents, printing only DONE" do
    pgpass
    argv = File.join(quaacks.home, "argv")
    container_pg_dump(before: %(printf '%s\\n' "$@" >> '#{argv}'))

    outcome = schema_dump

    expect([outcome.stdout, outcome.stderr, outcome.status.exitstatus]).to eq([done, "", 0])
    dump = stored.read("schema_dump")
    expect(dump["namespaces"]).to eq(%w[public sales])
    expect(created_tables(dump["ddl"])).to eq(%w[public.orders sales.items sales.unrelated])
    subset = stored.read("schema_subset")
    expect(subset["tables"]).to eq([%w[audit vendors], %w[public orders], %w[sales items]])
    expect(created_tables(subset["ddl"])).to eq(%w[audit.vendors public.orders sales.items])
    expect(subset["ddl"]).to include(sentinels.text)
    expect(File.read(argv).lines.grep(/\A--dbname=/).uniq).to eq(["--dbname=host='#{production.host}'\n"])
    expect_no_leaks(sentinels, outcome)
  end

  # While pg_dump runs, the step's own connection still holds the
  # transaction its catalog reads ran in: Production.read_only's. This
  # shows only that some transaction is open, not that it's read-only:
  # another session can't see transaction_read_only.
  it "reads the catalog inside a transaction" do
    pgpass
    states = File.join(quaacks.home, "states")
    container_pg_dump(before: <<~SH)
      [ "$1" = --version ] && docker exec -e PGPASSWORD='#{production.password}' \
        #{TestPostgres.server.container_id} psql -h 127.0.0.1 -U "$PGUSER" -d "$PGDATABASE" -Atc \
        "SELECT state FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()" \
        > '#{states}'
    SH

    expect(schema_dump.stdout).to eq(done)
    expect(File.read(states).split("\n")).to eq(["idle in transaction"])
  end

  # The step's connection sits idle in its transaction while pg_dump runs.
  # If production ends the session, the transaction's end fails, after
  # both dumps are done.
  it "stores nothing when the transaction fails after the dumps" do
    pgpass
    conn = production.connect
    role = %("#{production.user}" IN DATABASE "#{production.name}")
    conn.exec("ALTER ROLE #{role} SET idle_in_transaction_session_timeout = '1s'")
    conn.close
    container_pg_dump(before: %([ "$1" = --version ] || sleep 2))

    expect_failed(schema_dump, "production_read_failed")
  end

  it "refuses a pg_dump older than the server as pg_dump_too_old, and stores nothing" do
    pgpass
    pg_dump_script("echo 'pg_dump (PostgreSQL) 16.4'")

    expect_failed(schema_dump, "pg_dump_too_old")
  end

  it "fails as pg_dump_failed when pg_dump fails, never passing on what it printed" do
    pgpass
    pg_dump_script(%([ "$1" = --version ] && echo 'pg_dump (PostgreSQL) 99.0' && exit 0
                     echo '#{sentinels.text}'; echo '#{sentinels.text}' >&2; exit 1))

    expect_failed(schema_dump, "pg_dump_failed")
  end

  context "with a relation that's gone since qualify" do
    let(:relations) { [{ "schema" => "sales", "name" => "items" }, { "schema" => "sales", "name" => "gone" }] }

    it "refuses it as unknown_relation" do
      pgpass

      expect_failed(schema_dump, "unknown_relation")
    end
  end

  it "fails a bad password as production_connection_failed, naming neither the host nor the user" do
    pgpass(user: sentinels.word, password: sentinels.text)

    outcome = schema_dump(env: operator_env(PGUSER: sentinels.word))

    expect_failed(outcome, "production_connection_failed")
    expect(outcome.stdout).not_to include(production.host)
  end
end
