# frozen_string_literal: true

require "open3"
require "tmpdir"
require "quaack/enclave/schema_dump"
require "quaack/enclave/store"
require "quaack/enclave/error_filter"

# Every example runs real pg_dump against real Postgres. The dev Macs have
# no pg_dump 18, so pg_dump runs inside the harness's own container, through
# SchemaDump's command prefix, and connects over the container's Unix
# socket, the way the jump server's pg_dump uses the operator's own libpq
# setup.
#
# The sample schema (public.customers and public.orders, orders -> customers)
# gets more tables in more schemas. Arrows are FKs, from child to parent:
#
#   sales.items -> public.orders -> public.customers   (cross-schema, two levels)
#   sales.items -> sales.skus -> audit.vendors          (into a schema the query doesn't touch)
#   sales.items -> sales.warehouses                     (partitioned, with two partitions,
#                                                        one of them partitioned again)
#   sales.warehouse_east -> sales.zones                 (an FK of a partition's own)
#   sales.a -> sales.b -> sales.a                       (a cycle)
#   sales.b -> sales.regions -> sales.regions           (a self-reference)
#   sales.item_notes -> sales.items                     (a child, not a parent)
#
# plus sales.unrelated, other.lonely in a schema nothing touches, and
# audit.items and audit.a, which share a query table's name in another
# schema.
RSpec.describe Quaack::Enclave::SchemaDump do
  let(:db) { test_database }
  let(:conn) { db.connection }
  let(:conninfo) { { dbname: db.name, user: TestPostgres::USER } }
  let(:pg_dump) { ["docker", "exec", TestPostgres.server.container_id, "pg_dump"] }
  let(:store) { Quaack::Enclave::Store.create(base: @base) }

  around do |example|
    Dir.mktmpdir("quaack-schema-dump") do |dir|
      @base = File.join(dir, "runs")
      example.run
    end
  end

  def table(schema, name) = Quaack::Enclave::TableName.new(schema:, name:)

  def run(relations, conninfo: self.conninfo, pg_dump: self.pg_dump, **)
    described_class.run(store:, relations:, connection: conn, conninfo:, pg_dump:, **)
  end

  # A stand-in pg_dump, at the edge: a script that prints version for
  # --version, as pg_dump does, and runs rest for anything else.
  def fake_pg_dump(dir, version, rest = "exit 1")
    path = File.join(dir, "pg_dump")
    File.write(path, "#!/bin/sh\n[ \"$1\" = --version ] && echo '#{version}' && exit 0\n#{rest}\n")
    File.chmod(0o700, path)
    [path]
  end

  # The tables a dump creates, as "schema.name" the way pg_dump writes them.
  def created_tables(ddl) = ddl.scan(/^CREATE TABLE (.+) \($/).flatten.sort

  before do
    conn.exec(<<~SQL)
      CREATE SCHEMA sales;
      CREATE SCHEMA audit;
      CREATE SCHEMA other;
      CREATE TABLE audit.vendors (id int PRIMARY KEY);
      CREATE TABLE audit.items (id int);
      CREATE TABLE audit.a (id int);
      CREATE TABLE sales.skus (id int PRIMARY KEY, vendor_id int REFERENCES audit.vendors);
      CREATE TABLE sales.regions (id int PRIMARY KEY, parent_id int REFERENCES sales.regions);
      CREATE TABLE sales.zones (id int PRIMARY KEY);
      CREATE TABLE sales.warehouses (id int PRIMARY KEY, zone_id int) PARTITION BY RANGE (id);
      CREATE TABLE sales.warehouse_east PARTITION OF sales.warehouses FOR VALUES FROM (0) TO (100);
      ALTER TABLE sales.warehouse_east ADD FOREIGN KEY (zone_id) REFERENCES sales.zones;
      CREATE TABLE sales.warehouse_west PARTITION OF sales.warehouses FOR VALUES FROM (100) TO (200)
        PARTITION BY RANGE (id);
      CREATE TABLE sales.warehouse_west_low PARTITION OF sales.warehouse_west FOR VALUES FROM (100) TO (150);
      CREATE TABLE sales.items (
        id int PRIMARY KEY,
        order_id bigint REFERENCES public.orders,
        sku_id int REFERENCES sales.skus,
        warehouse_id int REFERENCES sales.warehouses
      );
      CREATE TABLE sales.item_notes (id int, item_id int REFERENCES sales.items);
      CREATE TABLE sales.a (id int PRIMARY KEY, b_id int);
      CREATE TABLE sales.b (id int PRIMARY KEY, a_id int REFERENCES sales.a, region_id int REFERENCES sales.regions);
      ALTER TABLE sales.a ADD FOREIGN KEY (b_id) REFERENCES sales.b;
      CREATE TABLE sales.unrelated (id int);
      CREATE TABLE other.lonely (id int);
    SQL
  end

  let(:subset) do
    %w[public.customers public.orders audit.vendors sales.items sales.skus sales.warehouses sales.warehouse_east
       sales.warehouse_west sales.warehouse_west_low sales.zones sales.regions sales.a sales.b]
  end

  describe "the subset" do
    it "is the query's tables and their whole FK ancestor chain, sorted, once each" do
      result = run([table("sales", "items"), table("sales", "a")])

      expect(result).to be_a(described_class::Result)
      expect(result.tables.map(&:to_s)).to eq(subset.sort)
      expect(result.tables.map(&:to_s)).not_to include("audit.items", "audit.a")
    end

    it "is stored as the pg_dump of just those tables, schema only, with no owners or privileges" do
      conn.exec("GRANT SELECT ON sales.items TO PUBLIC")
      run([table("sales", "items"), table("sales", "a")])

      stored = store.read("schema_subset")
      expect(stored.keys).to eq(%w[tables ddl])
      expect(stored["tables"]).to eq(subset.sort.map { it.split(".") })
      expect(created_tables(stored["ddl"])).to eq(subset.sort)
      expect(created_tables(stored["ddl"])).not_to include("audit.items", "audit.a")
      expect(stored["ddl"])
        .to include("ADD CONSTRAINT items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id)")
      expect(stored["ddl"]).not_to match(/OWNER TO|GRANT|^COPY |INSERT INTO/)
    end

    # Byte order puts every capital before every lowercase letter, as Ruby's
    # sort does for the namespaces. A linguistic collation wouldn't.
    it "is sorted by byte, whatever the database's collation" do
      conn.exec(<<~SQL)
        CREATE SCHEMA "Upper";
        CREATE TABLE sales.alpha (id int PRIMARY KEY);
        CREATE TABLE sales."Beta" (id int PRIMARY KEY);
        CREATE TABLE sales."Zeta" (id int, alpha_id int REFERENCES sales.alpha, beta_id int REFERENCES sales."Beta");
        CREATE TABLE "Upper".t (id int);
      SQL
      expect(conn.exec("SELECT datcollate FROM pg_database WHERE datname = current_database()").getvalue(0, 0))
        .not_to eq("C")

      result = run([table("sales", "Zeta"), table("Upper", "t")])

      expect(result.tables.map(&:to_s)).to eq(%w[Upper.t sales.Beta sales.Zeta sales.alpha])
      expect(result.namespaces).to eq(%w[Upper public sales])
    end

    # pg_dump with no --table dumps every table, so it isn't run.
    it "is empty for a query that uses no tables" do
      result = run([])

      expect(result.tables).to eq([])
      expect(store.read("schema_subset")).to eq({ "tables" => [], "ddl" => "" })
      expect(created_tables(store.read("schema_dump")["ddl"])).to eq(%w[public.customers public.orders])
    end

    it "refuses a relation the catalog doesn't have, and stores nothing" do
      expect { run([table("sales", "items"), table("sales", "gone")]) }
        .to refused("unknown_relation", "sales.gone doesn't exist")
      nothing_stored
    end
  end

  describe "the full dump" do
    it "is stored as the schema-only pg_dump of every schema the query touches, plus public" do
      conn.exec("GRANT SELECT ON sales.items TO PUBLIC")
      result = run([table("sales", "items")])

      expect(result.namespaces).to eq(%w[public sales])
      stored = store.read("schema_dump")
      expect(stored.keys).to eq(%w[namespaces ddl])
      expect(stored["namespaces"]).to eq(%w[public sales])
      expect(created_tables(stored["ddl"])).to eq(
        %w[public.customers public.orders sales.a sales.b sales.item_notes sales.items sales.regions sales.skus
           sales.unrelated sales.warehouse_east sales.warehouse_west sales.warehouse_west_low sales.warehouses
           sales.zones]
      )
      expect(stored["ddl"]).not_to match(/OWNER TO|GRANT|^COPY |INSERT INTO/)
    end

    it "includes public even when the query doesn't touch it" do
      result = run([table("other", "lonely")])

      expect(result.namespaces).to eq(%w[other public])
      expect(created_tables(store.read("schema_dump")["ddl"])).to eq(%w[other.lonely public.customers public.orders])
    end

    # Arena setup drops public before loading, so the dump must create it.
    it "creates public itself, as pg_dump 18 does for a schema named with --schema" do
      run([table("other", "lonely")])
      expect(store.read("schema_dump")["ddl"]).to match(/^CREATE SCHEMA public;$/)
    end

    # --strict-names would fail the dump on a --schema for a public that
    # isn't there.
    it "leaves out public when the database has none" do
      conn.exec("DROP SCHEMA public CASCADE")
      result = run([table("other", "lonely")])

      expect(result.namespaces).to eq(%w[other])
      expect(store.read("schema_dump")["namespaces"]).to eq(%w[other])
      expect(created_tables(store.read("schema_dump")["ddl"])).to eq(%w[other.lonely])
    end
  end

  # pg_dump with --schema emits no CREATE EXTENSION, so without --extension
  # the full dump fails to load on a column of an extension's type.
  describe "extensions" do
    let(:target) { "quaack_ext_load_#{Process.pid}" }
    let(:admin) { TestPostgres.server.admin }

    before do
      conn.exec(<<~SQL)
        CREATE EXTENSION citext SCHEMA public;
        CREATE SCHEMA ext;
        CREATE EXTENSION pgcrypto SCHEMA ext;
        CREATE TABLE other.tagged (id int, tag public.citext, salt bytea DEFAULT ext.gen_random_bytes(4));
      SQL
    end

    after { admin.exec(%(DROP DATABASE IF EXISTS "#{target}" WITH (FORCE))) }

    it "are in the full dump, with their schemas, so it loads into a fresh template0 database" do
      result = run([table("other", "tagged")])
      ddl = store.read("schema_dump")["ddl"]

      expect(result.namespaces).to eq(%w[ext other public])
      expect(ddl).to include("CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public")
        .and include("CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA ext")
      expect(ddl).not_to include("plpgsql")

      admin.exec(%(CREATE DATABASE "#{target}" TEMPLATE template0))
      # The dump's own CREATE SCHEMA public would clash with template0's.
      PG.connect(**db.connection_params, dbname: target).tap { it.exec("DROP SCHEMA public") }.close
      out, status = Open3.capture2e("docker", "exec", "-i", TestPostgres.server.container_id, "psql", "-X", "-q",
                                    "-v", "ON_ERROR_STOP=1", "-U", TestPostgres::USER, "-d", target, stdin_data: ddl)
      expect(status.success?).to be(true), out
      loaded = PG.connect(**db.connection_params, dbname: target)
      type = loaded.exec("SELECT format_type(atttypid, NULL) FROM pg_attribute " \
                         "WHERE attrelid = 'other.tagged'::regclass AND attname = 'tag'").getvalue(0, 0)
      expect(type).to eq("citext")
      loaded.close
    end
  end

  # pg_dump reads --schema and --table as patterns: unquoted, it folds case
  # and takes * and ? as wildcards. Each name goes in quoted, so it matches
  # only itself.
  describe "names pg_dump would read as patterns" do
    before do
      conn.exec(<<~SQL)
        CREATE SCHEMA "Odd";
        CREATE SCHEMA odd;
        CREATE TABLE "Odd"."Wild*" (id int);
        CREATE TABLE "Odd"."wildcard" (id int);
        CREATE TABLE "Odd"."wild" (id int);
        CREATE TABLE "Odd"."say ""hi""" (id int);
        CREATE TABLE odd.wild (id int);
      SQL
    end

    it "dumps only the tables and schemas named, exactly" do
      result = run([table("Odd", "Wild*"), table("Odd", 'say "hi"')])

      expect(result.namespaces).to eq(%w[Odd public])
      expect(created_tables(store.read("schema_subset")["ddl"])).to eq(['"Odd"."Wild*"', '"Odd"."say ""hi"""'])
      expect(created_tables(store.read("schema_dump")["ddl"])).to eq(
        ['"Odd"."Wild*"', '"Odd"."say ""hi"""', '"Odd".wild', '"Odd".wildcard', "public.customers", "public.orders"]
      )
    end
  end

  # A schema-only dump has no rows in it. The tables in both dumps get
  # sentinel rows, most common values, and histogram bounds, and none of
  # them may turn up in anything stored or returned.
  describe "the data in the tables" do
    let(:sentinels) { LeakCheck::Sentinels.new }

    before do
      LeakCheck::Fixture.plant(db, sentinels)
      conn.exec(<<~SQL)
        ALTER TABLE sales.unrelated ADD COLUMN note text;
        INSERT INTO sales.unrelated SELECT i, '#{sentinels.text}' FROM generate_series(1, 100) AS i;
        INSERT INTO audit.vendors VALUES (#{sentinels.number});
        INSERT INTO sales.skus VALUES (1, #{sentinels.number});
        ANALYZE;
      SQL
    end

    it "never reaches the stored dumps, any other stored file, or the result" do
      result = run([table("sales", "items"), table("sales", "a")])

      everything = [pg_dump, "--dbname=dbname=#{db.name} user=postgres"].flatten
      data, = Open3.capture3(*everything)
      expect(data).to include(sentinels.text, sentinels.word, sentinels.number.to_s)
      stored = Dir.children(store.path).sort
      expect(stored).to eq(%w[schema_dump.json schema_subset.json])
      files = stored.map { File.read(File.join(store.path, it)) }.join("\n")
      expect_no_leaks(sentinels, stdout: files, objects: { result: })
    end
  end

  # The store keeps JSON, which must be UTF-8, whatever the production
  # database's encoding is, and whatever the jump server's locale is.
  describe "a database that isn't UTF-8" do
    let(:latin1) { "quaack_latin1_#{Process.pid}" }
    let(:admin) { TestPostgres.server.admin }
    let(:latin1_conn) { PG.connect(**db.connection_params, dbname: latin1) }

    before do
      admin.exec("CREATE DATABASE #{latin1} ENCODING 'LATIN1' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0")
      latin1_conn.exec("CREATE TABLE public.menu (id int)")
      latin1_conn.exec("COMMENT ON TABLE public.menu IS 'café'")
    end

    after do
      latin1_conn.close
      admin.exec("DROP DATABASE IF EXISTS #{latin1} WITH (FORCE)")
    end

    it "is dumped as UTF-8, even when Ruby's default encoding isn't" do
      external = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      described_class.run(store:, relations: [table("public", "menu")], connection: latin1_conn,
                          conninfo: { dbname: latin1, user: TestPostgres::USER }, pg_dump:)
      Encoding.default_external = external

      %w[schema_dump schema_subset].each do |entry|
        expect(store.read(entry)["ddl"]).to include("COMMENT ON TABLE public.menu IS 'café';")
      end
    ensure
      Encoding.default_external = external
    end

    # The connection's client encoding is the database's, LATIN1, so the
    # catalog's names come back in it unless they're read as UTF-8, and a
    # UTF-8 name from the query wouldn't match them.
    it "finds non-ASCII table names in the chain, and leaves the connection's encoding as it was" do
      latin1_conn.exec('CREATE TABLE public."café" (id int PRIMARY KEY)')
      latin1_conn.exec('CREATE TABLE public."naïve" (id int, cafe_id int REFERENCES public."café")')
      expect(latin1_conn.internal_encoding).to eq(Encoding::ISO_8859_1)

      result = described_class.run(store:, relations: [table("public", "naïve")], connection: latin1_conn,
                                   conninfo: { dbname: latin1, user: TestPostgres::USER }, pg_dump:)

      expect(result.tables).to eq([table("public", "café"), table("public", "naïve")])
      expect(created_tables(store.read("schema_subset")["ddl"])).to eq(['public."café"', 'public."naïve"'])
      expect(latin1_conn.exec("SHOW client_encoding").getvalue(0, 0)).to eq("LATIN1")
      expect(latin1_conn.internal_encoding).to eq(Encoding::ISO_8859_1)
    end
  end

  describe "the connection parameters" do
    it "reach pg_dump as one libpq connection string, whatever their values hold" do
      odd = "quaack_it's \\odd_#{Process.pid}"
      admin = TestPostgres.server.admin
      admin.exec("CREATE DATABASE #{admin.quote_ident(odd)}")
      PG.connect(**db.connection_params, dbname: odd).tap { it.exec("CREATE TABLE public.here (id int)") }.close

      ddl = described_class.dump(pg_dump, { dbname: odd, user: TestPostgres::USER }, [%(--table="public"."here")])

      expect(created_tables(ddl)).to eq(["public.here"])
    ensure
      admin&.exec("DROP DATABASE IF EXISTS #{admin.quote_ident(odd)} WITH (FORCE)")
    end

    # Each libpq keyword that holds a secret, as a Symbol or a String.
    [:password, "password", :sslpassword, "sslpassword", :oauth_client_secret].each do |key|
      it "can't hold a secret (#{key.inspect}), since pg_dump's command line is visible to others on the jump server" do
        sentinels = LeakCheck::Sentinels.new
        error = nil
        expect { run([table("sales", "items")], conninfo: { **conninfo, key => sentinels.text }) }
          .to(refused("secret_in_conninfo", "pg_dump gets its secrets from the operator's own libpq setup") do |e|
            error = e
          end)
        nothing_stored
        expect(error).to be_a(described_class::Error)
        expect_no_leaks(sentinels, objects: { error: })
      end
    end

    # passfile names a file, and isn't a secret itself.
    it "can name a password file" do
      run([table("sales", "items")], conninfo: { **conninfo, passfile: "/nonexistent/quaack/pgpass" })

      expect(store.read("schema_subset")["tables"]).to include(%w[sales items])
    end
  end

  # The Error for rule, with message, and no cause. The block, if any,
  # gets the error too, so the example can scan it.
  def refused(rule, message, &also)
    raise_error(described_class::Error, "#{rule}: #{message}") do |error|
      expect([error.rule, error.cause]).to eq([rule, nil])
      also&.call(error)
    end
  end

  def nothing_stored = expect(Dir.children(store.path)).to eq([])

  describe "pg_dump itself" do
    it "must be at least the server's major version, since pg_dump refuses an older one" do
      Dir.mktmpdir do |dir|
        expect { run([table("sales", "items")], pg_dump: fake_pg_dump(dir, "pg_dump (PostgreSQL) 17.6")) }
          .to refused("pg_dump_too_old", "pg_dump is major version 17, older than the server's 18")
      end
      nothing_stored
    end

    it "is refused when it isn't there" do
      expect { run([table("sales", "items")], pg_dump: ["/nonexistent/quaack/pg_dump"]) }
        .to refused("pg_dump_missing", "pg_dump couldn't be run, or didn't say its version")
      nothing_stored
    end

    ["something else 18.1", "not pg_dump (PostgreSQL) 18.1"].each do |output|
      it "is refused when it doesn't say its version the way pg_dump does (#{output.inspect})" do
        Dir.mktmpdir do |dir|
          expect { run([table("sales", "items")], pg_dump: fake_pg_dump(dir, output)) }
            .to refused("pg_dump_missing", "pg_dump couldn't be run, or didn't say its version")
        end
        nothing_stored
      end
    end

    it "is refused, with no exit status, when a signal kills it" do
      Dir.mktmpdir do |dir|
        killed = fake_pg_dump(dir, "pg_dump (PostgreSQL) 18.4", "kill -KILL $$")
        expect { run([table("sales", "items")], pg_dump: killed) }
          .to refused("pg_dump_failed", "pg_dump exited with status none (a signal)")
      end
      nothing_stored
    end
  end

  # pg_dump's stderr carries the server's messages, and names what it was
  # asked for, so none of it goes into an error. Only its exit status does.
  describe "a pg_dump that fails" do
    let(:sentinels) { LeakCheck::Sentinels.new }

    # What pg_dump itself says on stderr for argv, run straight, to show
    # the sentinel was really there to leak.
    def pg_dump_stderr(*argv)
      _out, err, status = Open3.capture3(*pg_dump, *argv)
      expect(status.success?).to be(false)
      err
    end

    it "is refused with its exit status, and nothing it said, when it can't connect" do
      error = nil
      bad = { dbname: sentinels.word, user: TestPostgres::USER }
      expect { run([table("sales", "items")], conninfo: bad) }
        .to refused("pg_dump_failed", "pg_dump exited with status 1") { error = it }

      expect(pg_dump_stderr("--schema-only", "--dbname=dbname=#{sentinels.word} user=postgres"))
        .to include(sentinels.word)
      nothing_stored
      expect(error).to be_a(described_class::Error)
      expect_no_leaks(sentinels, stdout: Quaack::Enclave::ErrorFilter.to_egress(error, step: "3b"), objects: { error: })
    end

    # pg_dump takes an ACCESS SHARE lock on each table it dumps. Rather
    # than wait behind a long ACCESS EXCLUSIVE lock on production, it gives
    # up. Its exit status is 1, as for any other failure, and its stderr
    # isn't read, so it's pg_dump_failed too. The lock is let go after
    # release seconds whatever happens, so a pg_dump that would wait
    # forever finishes, and the example fails rather than hanging.
    it "gives up waiting for a table's lock after the lock wait timeout" do
      release = 15
      done = Queue.new
      blocker = db.connect
      blocker.exec("BEGIN")
      blocker.exec("LOCK TABLE sales.items IN ACCESS EXCLUSIVE MODE")
      watchdog = Thread.new do
        done.pop(timeout: release)
        blocker.exec("ROLLBACK")
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      expect { run([table("sales", "items")], lock_wait_timeout: "1s") }
        .to refused("pg_dump_failed", "pg_dump exited with status 1")

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < release
      nothing_stored
    ensure
      done << true
      watchdog&.join
      blocker&.close
    end

    it "is refused when a table it's asked for isn't there, even alongside one that is" do
      error = nil
      missing = "--table=#{described_class.pattern("sales", sentinels.word)}"
      expect { described_class.dump(pg_dump, conninfo, [%(--table="sales"."items"), missing]) }
        .to refused("pg_dump_failed", "pg_dump exited with status 1") { error = it }

      expect(pg_dump_stderr("--schema-only", "--strict-names", missing, "--dbname=dbname=#{db.name} user=postgres"))
        .to include(sentinels.word)
      expect(error).to be_a(described_class::Error)
      expect_no_leaks(sentinels, stdout: Quaack::Enclave::ErrorFilter.to_egress(error, step: "3b"), objects: { error: })
    end
  end
end
