# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

# The test database harness in spec/support/test_postgres.rb. These run
# against the real container, since the harness is the thing that gives every
# other suite a real Postgres.
RSpec.describe TestPostgres do
  def value(db, sql) = db.connection.exec(sql).getvalue(0, 0)

  def docker_ids(*filters)
    out, status = Open3.capture2("docker", "ps", "-a", "-q", "--no-trunc", *filters.flat_map { |f| ["--filter", f] })
    raise "docker ps failed" unless status.success?

    out.split
  end

  # Runs a spec file in a child process that inherits this bundle, the way
  # rake runs a suite, and returns its output and status.
  def run_child_spec(source, env: {})
    Dir.mktmpdir do |dir|
      file = File.join(dir, "child_spec.rb")
      File.write(file, source)
      out, status = Open3.capture2e(env, RbConfig.ruby, "-rrspec/core", "-e", "RSpec::Core::Runner.invoke", "--", file,
                                    chdir: REPO_ROOT)
      [out, status]
    end
  end

  # RSpec prints its progress dots on the same line, so this isn't anchored.
  def child_value(out, key) = out[/\b#{key}=(\S*)/, 1]

  it "runs Postgres 18" do
    expect(value(test_database, "SHOW server_version_num").to_i).to be_between(180_000, 189_999)
  end

  it "has HypoPG available to install" do
    names = test_database.connection.exec("SELECT name FROM pg_available_extensions").column_values(0)

    expect(names).to include("hypopg")
  end

  it "gives each request a fresh database, so what one test creates the next can't see" do
    first = TestPostgres.create_database
    first.connection.exec("CREATE TABLE leftover (id int)")
    second = TestPostgres.create_database

    expect(second.name).not_to eq(first.name)
    expect(value(first, "SELECT to_regclass('leftover') IS NOT NULL")).to eq("t")
    expect(value(second, "SELECT to_regclass('leftover') IS NOT NULL")).to eq("f")
  end

  it "drops the databases it created when asked" do
    db = TestPostgres.create_database
    expect(TestPostgres.server.database_names).to include(db.name)

    TestPostgres.drop_databases

    expect(TestPostgres.server.database_names).not_to include(db.name)
  end

  describe "the sample schema" do
    def stats(db, table, column)
      db.connection.exec_params(<<~SQL, [table, column]).first.to_h
        SELECT null_frac, n_distinct, correlation,
               most_common_vals::text AS mcv, most_common_freqs::text AS mcf,
               histogram_bounds IS NOT NULL AS has_histogram
        FROM pg_stats WHERE schemaname = 'public' AND tablename = $1 AND attname = $2
      SQL
    end

    it "has customers and orders, with an FK from orders to customers and the existing indexes" do
      db = test_database
      fk = value(db, <<~SQL)
        SELECT confrelid::regclass::text FROM pg_constraint
        WHERE conrelid = 'orders'::regclass AND contype = 'f'
      SQL
      indexes = db.connection.exec("SELECT indexname FROM pg_indexes WHERE schemaname = 'public'").column_values(0)

      expect(fk).to eq("customers")
      expect(indexes).to include("orders_customer_id_idx", "orders_status_created_at_idx", "customers_email_key")
    end

    it "has rows in both tables" do
      db = test_database

      expect(value(db, "SELECT count(*) FROM customers").to_i).to eq(2_000)
      expect(value(db, "SELECT count(*) FROM orders").to_i).to eq(20_000)
    end

    it "is analyzed, so pg_stats has MCVs, histogram bounds, and correlation" do
      db = test_database
      status = stats(db, "orders", "status")
      created_at = stats(db, "orders", "created_at")
      name = stats(db, "customers", "name")

      expect(status["mcv"]).to eq("{delivered,shipped,pending,cancelled,returned,failed}")
      expect(status["mcf"]).to eq("{0.71,0.12,0.09,0.04,0.03,0.01}")
      expect(created_at["has_histogram"]).to eq("t")
      expect(created_at["correlation"].to_f).to be > 0.99
      expect(name["null_frac"].to_f).to be_within(0.001).of(0.02)
      expect(name["n_distinct"].to_f).to be < -0.9
    end
  end

  describe "racetrack and arena" do
    it "are two different databases in the same container" do
      pair = racetrack_and_arena
      where = "SELECT current_database() || ':' || inet_server_port()"
      seen = [pair.racetrack, pair.arena].map { |db| value(db, where) }

      expect(pair.racetrack.name).not_to eq(pair.arena.name)
      expect([pair.racetrack.port, pair.arena.port].uniq).to eq([TestPostgres.server.port])
      expect(seen).to eq(["#{pair.racetrack.name}:5432", "#{pair.arena.name}:5432"])
    end

    it "give racetrack the sample data and arena the same schema with no rows" do
      pair = racetrack_and_arena

      expect(value(pair.racetrack, "SELECT count(*) FROM orders").to_i).to eq(20_000)
      expect(value(pair.arena, "SELECT count(*) FROM orders").to_i).to eq(0)
      expect(value(pair.arena, "SELECT count(*) FROM customers").to_i).to eq(0)
    end
  end

  describe "in a spec process of its own" do
    let(:child_source) do
      <<~RUBY
        require #{File.join(REPO_ROOT, "spec", "support", "test_postgres").inspect}
        RSpec.configure { |c| TestPostgres.configure(c) }
        FIRST = []
        RSpec.describe "a tiny suite", order: :defined do
          it "creates a table" do
            FIRST << test_database.name
            test_database.connection.exec("CREATE TABLE leftover (id int)")
            puts "CONTAINER=\#{TestPostgres.server.container_id}"
          end

          it "looks for it" do
            puts "FIRST_SAME=\#{test_database.name == FIRST[0]}"
            puts "LEFTOVER=\#{test_database.connection.exec("SELECT to_regclass('leftover') IS NOT NULL").getvalue(0, 0)}"
            puts "FIRST_EXISTS=\#{TestPostgres.server.database_names.include?(FIRST[0])}"
          end
        end
      RUBY
    end

    it "gives each test its own database, drops it afterward, and removes the container at exit" do
      out, status = run_child_spec(child_source)
      container = child_value(out, "CONTAINER")

      expect(status).to be_success, out
      expect(container).to match(/\A\h{64}\z/)
      expect(child_value(out, "FIRST_SAME")).to eq("false")
      expect(child_value(out, "LEFTOVER")).to eq("f")
      expect(child_value(out, "FIRST_EXISTS")).to eq("false")
      expect(docker_ids("id=#{container}")).to be_empty
    end

    it "removes stale containers left by a dead process, but not ones whose process is alive" do
      mine = TestPostgres.server.container_id
      dead_pid = Process.spawn(RbConfig.ruby, "-e", "exit")
      Process.wait(dead_pid)
      stale, = Open3.capture2("docker", "create", "--label", "#{TestPostgres::LABEL}=1",
                              "--label", "#{TestPostgres::OWNER_LABEL}=#{dead_pid}", TestPostgres.image_tag)
      stale = stale.strip

      begin
        out, status = run_child_spec(child_source)

        expect(status).to be_success, out
        expect(docker_ids("id=#{stale}")).to be_empty
        expect(docker_ids("id=#{mine}", "status=running")).to eq([mine])
      ensure
        Open3.capture2e("docker", "rm", "-f", "-v", stale)
      end
    end

    describe "without Docker" do
      let(:source) do
        <<~RUBY
          require #{File.join(REPO_ROOT, "spec", "support", "test_postgres").inspect}
          RSpec.configure { |c| TestPostgres.configure(c) }
          RSpec.describe("no docker") { it("needs a database") { test_database } }
        RUBY
      end

      it "fails loudly, not with a skip, when there's no docker command" do
        out, status = run_child_spec(source, env: { "PATH" => RbConfig::CONFIG["bindir"] })

        expect(status).not_to be_success
        expect(out).to include("1 example, 1 failure")
        expect(out).to include("TestPostgres needs Docker, and there's no docker command on PATH")
      end

      it "fails loudly, not with a skip, when the daemon isn't reachable" do
        out, status = run_child_spec(source, env: { "DOCKER_HOST" => "unix:///nonexistent/docker.sock" })

        expect(status).not_to be_success
        expect(out).to include("1 example, 1 failure")
        expect(out).to include("TestPostgres needs Docker, and the Docker daemon isn't reachable")
      end
    end
  end
end
