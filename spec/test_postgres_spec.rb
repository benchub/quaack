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

  # RSpec prints its progress marks (. and F) on the same line, so this isn't
  # anchored. No key is a suffix of another.
  def child_value(out, key) = out[/#{key}=(\S*)/, 1]

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

  it "drops both of a racetrack and arena pair" do
    pair = TestPostgres.create_run_server
    names = [pair.racetrack.name, pair.arena.name]
    expect(TestPostgres.server.database_names).to include(*names)

    TestPostgres.drop_databases

    expect(TestPostgres.server.database_names & names).to be_empty
  end

  # DROP ... WITH (FORCE) would end the backends anyway, so this checks the
  # client side: the harness closes its own connections rather than leaving
  # FORCE to cut them off.
  it "closes its connections to a database before dropping it" do
    pair = TestPostgres.create_run_server
    conns = [TestPostgres.create_database, pair.racetrack, pair.arena].map(&:connection)

    TestPostgres.drop_databases

    expect(conns.map(&:finished?)).to eq([true, true, true])
  end

  # A connection from `connect` that a test drops without closing must be
  # free to be garbage-collected, which closes its socket. If the harness
  # kept a reference to it, the socket would stay open until the process
  # ran out of file descriptors.
  it "lets go of connections a test drops without closing" do
    open_fds = -> { Dir.children("/dev/fd").size }
    db = test_database
    before = open_fds.call

    40.times { db.connect.exec("SELECT 1") }
    GC.start

    expect(open_fds.call - before).to be < 5
  end

  it "drops a database that a session from connect still holds open" do
    db = TestPostgres.create_database
    held = db.connect

    TestPostgres.drop_databases

    expect(TestPostgres.server.database_names).not_to include(db.name)
  ensure
    held&.close
  end

  it "replaces an admin connection a spec left inside a transaction" do
    TestPostgres.server.admin.exec("BEGIN")

    expect(TestPostgres.create_database.name).to start_with("quaack_test_")
  end

  # This machine already has the image, so a fake docker that has none
  # shows the build happens.
  it "builds the image when docker has none with its tag" do
    Dir.mktmpdir do |dir|
      log = File.join(dir, "calls.log")
      File.write(File.join(dir, "docker"), <<~SH, perm: 0o755)
        #!/bin/sh
        echo "$*" >> #{log}
        [ "$1" != image ]
      SH
      path = ENV.fetch("PATH")
      begin
        ENV["PATH"] = "#{dir}#{File::PATH_SEPARATOR}#{path}"
        TestPostgres.build_image
      ensure
        ENV["PATH"] = path
      end

      expect(File.readlines(log, chomp: true))
        .to eq(["image inspect #{TestPostgres.image_tag}", "build -q -t #{TestPostgres.image_tag} #{TestPostgres::DIR}"])
    end
  end

  it "counts a process it may not signal as alive" do
    expect(TestPostgres.process_alive?(1)).to be(true)
  end

  it "returns the same database for every call within one example" do
    expect(test_database).to equal(test_database)
    expect(racetrack_and_arena).to equal(racetrack_and_arena)
  end

  it "runs with autovacuum off, as the run server does" do
    expect(value(test_database, "SHOW autovacuum")).to eq("off")
  end

  it "publishes Postgres only on 127.0.0.1" do
    server = TestPostgres.server
    out, status = Open3.capture2("docker", "port", server.container_id, "5432/tcp")

    expect(status).to be_success
    expect(out.lines.map(&:strip)).to eq(["127.0.0.1:#{server.port}"])
  end

  describe "PgBouncer" do
    def through_pgbouncer(db) = PG.connect(**db.connection_params, port: TestPostgres.server.pgbouncer_port)

    it "publishes it only on 127.0.0.1" do
      server = TestPostgres.server
      port = server.pgbouncer_port
      out, status = Open3.capture2("docker", "port", server.container_id, "6432/tcp")

      expect(status).to be_success
      expect(out.lines.map(&:strip)).to eq(["127.0.0.1:#{port}"])
    end

    # In session mode a client keeps one server backend for its session,
    # and the pid libpq reports is PgBouncer's own, not that backend's.
    it "pools in session mode, in front of the test server, and reports a pid of its own" do
      conn = through_pgbouncer(test_database)
      begin
        server_pid = Integer(conn.exec("SELECT pg_backend_pid()").getvalue(0, 0), 10)
        listed = TestPostgres.server.admin.exec_params("SELECT datname FROM pg_stat_activity WHERE pid = $1",
                                                       [server_pid])

        expect(listed.column_values(0)).to eq([test_database.name])
        expect(conn.exec("SELECT pg_backend_pid()").getvalue(0, 0)).to eq(server_pid.to_s)
        expect(conn.backend_pid).not_to eq(server_pid)
      ensure
        conn.close
      end
    end

    def server_pid(conn) = conn.exec("SELECT pg_backend_pid()").getvalue(0, 0)

    # In transaction mode, the second client would get the first one's idle
    # backend.
    it "keeps each client on its own server backend for its whole session" do
      first = through_pgbouncer(test_database)
      second = through_pgbouncer(test_database)
      begin
        first_pid = server_pid(first)

        expect(server_pid(second)).not_to eq(first_pid)
        expect(server_pid(first)).to eq(first_pid)
      ensure
        [first, second].each(&:close)
      end
    end

    it "keeps a closed client's server backend in its pool" do
      conn = through_pgbouncer(test_database)
      server_pid = conn.exec("SELECT pg_backend_pid()").getvalue(0, 0)
      conn.close

      alive = TestPostgres.server.admin.exec_params("SELECT count(*) FROM pg_stat_activity WHERE pid = $1",
                                                    [server_pid])
      expect(alive.getvalue(0, 0)).to eq("1")
    end
  end

  describe "the image tag" do
    def tag_for(dockerfile_text)
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "Dockerfile"), dockerfile_text)
        TestPostgres.image_tag(dir)
      end
    end

    let(:dockerfile) { File.read(File.join(TestPostgres::DIR, "Dockerfile")) }

    it "is what the running container was started from" do
      image, = Open3.capture2("docker", "inspect", "--format", "{{.Config.Image}}", TestPostgres.server.container_id)

      expect(image.strip).to eq(TestPostgres.image_tag)
    end

    it "comes from the Dockerfile's contents, so an edit gets a new tag" do
      expect(tag_for(dockerfile)).to eq(TestPostgres.image_tag)
      expect(tag_for("#{dockerfile}# an edit\n")).not_to eq(TestPostgres.image_tag)
      expect(tag_for("#{dockerfile}# an edit\n")).to match(/\Aquaack-test-postgres:\h{12}\z/)
    end
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
    # An around hook wraps every before and after hook, whatever order they
    # were registered in, so this runs once the harness has finished with an
    # example. It prints how many of this process's test databases are left.
    let(:watch) do
      <<~RUBY
        RSpec.configure do |c|
          c.around do |example|
            example.run
            left = TestPostgres.server.database_names.grep(/\\Aquaack_test_\#{Process.pid}_/)
            puts "\#{example.metadata[:key]}=\#{left.size}"
          end
        end
      RUBY
    end

    let(:child_source) do
      <<~RUBY
        require #{File.join(REPO_ROOT, "spec", "support", "test_postgres").inspect}
        RSpec.configure { |c| TestPostgres.configure(c) }
        #{watch}
        FIRST = []
        RSpec.describe "a tiny suite", order: :defined do
          it "creates a table", key: "AFTER_ONE" do
            FIRST << test_database.name
            test_database.connection.exec("CREATE TABLE leftover (id int)")
            puts "CONTAINER=\#{TestPostgres.server.container_id}"
            puts "DURING_ONE=\#{TestPostgres.server.database_names.include?(FIRST[0])}"
          end

          it "looks for it", key: "AFTER_TWO" do
            puts "FIRST_SAME=\#{test_database.name == FIRST[0]}"
            puts "LEFTOVER=\#{test_database.connection.exec("SELECT to_regclass('leftover') IS NOT NULL").getvalue(0, 0)}"
          end
        end
      RUBY
    end

    it "gives each test its own database, drops it at the end of that test, and removes the container at exit" do
      out, status = run_child_spec(child_source)
      container = child_value(out, "CONTAINER")

      expect(status).to be_success, out
      expect(container).to match(/\A\h{64}\z/)
      expect(child_value(out, "DURING_ONE")).to eq("true")
      expect(child_value(out, "AFTER_ONE")).to eq("0")
      expect(child_value(out, "FIRST_SAME")).to eq("false")
      expect(child_value(out, "LEFTOVER")).to eq("f")
      expect(child_value(out, "AFTER_TWO")).to eq("0")
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

    it "removes a container labeled with this host whose process is dead" do
      dead_pid = Process.spawn(RbConfig.ruby, "-e", "exit")
      Process.wait(dead_pid)
      stale, = Open3.capture2("docker", "create", "--label", "#{TestPostgres::LABEL}=1",
                              "--label", "#{TestPostgres::OWNER_LABEL}=#{dead_pid}",
                              "--label", "#{TestPostgres::HOST_LABEL}=#{Socket.gethostname}",
                              TestPostgres.image_tag)
      stale = stale.strip

      begin
        out, status = run_child_spec(child_source)

        expect(status).to be_success, out
        expect(docker_ids("id=#{stale}")).to be_empty
      ensure
        Open3.capture2e("docker", "rm", "-f", "-v", stale)
      end
    end

    it "leaves a container owned by another host, even if its pid isn't alive here" do
      dead_pid = Process.spawn(RbConfig.ruby, "-e", "exit")
      Process.wait(dead_pid)
      foreign, = Open3.capture2("docker", "create", "--label", "#{TestPostgres::LABEL}=1",
                                "--label", "#{TestPostgres::OWNER_LABEL}=#{dead_pid}",
                                "--label", "#{TestPostgres::HOST_LABEL}=not-#{Socket.gethostname}",
                                TestPostgres.image_tag)
      foreign = foreign.strip

      begin
        out, status = run_child_spec(child_source)

        expect(status).to be_success, out
        expect(docker_ids("id=#{foreign}")).to eq([foreign])
      ensure
        Open3.capture2e("docker", "rm", "-f", "-v", foreign)
      end
    end

    it "labels its container with this host's name" do
      id = TestPostgres.server.container_id
      host = TestPostgres.docker("inspect", "--format", "{{index .Config.Labels \"#{TestPostgres::HOST_LABEL}\"}}", id)
      expect(host).to eq(Socket.gethostname)
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

    let(:prelude) do
      <<~RUBY
        require #{File.join(REPO_ROOT, "spec", "support", "test_postgres").inspect}
        RSpec.configure { |c| TestPostgres.configure(c) }
      RUBY
    end

    it "drops an example's databases at the end of that example, even when it fails" do
      source = <<~RUBY
        #{prelude}
        #{watch}
        RSpec.describe "a failing example" do
          it("fails", key: "AFTER_FAIL") do
            test_database
            racetrack_and_arena
            puts "DURING_FAIL=\#{TestPostgres.server.database_names.grep(/\\Aquaack_test_\#{Process.pid}_/).size}"
            raise "planted"
          end
        end
      RUBY
      out, status = run_child_spec(source)

      expect(status).not_to be_success
      expect(out).to include("1 example, 1 failure")
      expect(child_value(out, "DURING_FAIL")).to eq("3"), out
      expect(child_value(out, "AFTER_FAIL")).to eq("0"), out
    end

    # Postgres won't drop a template database, so this drop fails every time
    # it's tried. It should fail only its own example, and the example's
    # other databases should still be dropped.
    it "forgets an example's databases when one of its drops fails, and still drops the rest" do
      source = <<~RUBY
        #{prelude}
        #{watch}
        RSpec.describe "an undroppable database", order: :defined do
          it("marks it", key: "AFTER_MARKED") do
            TestPostgres.server.admin.exec("ALTER DATABASE \#{test_database.name} IS_TEMPLATE true")
            racetrack_and_arena
          end

          it("runs next", key: "AFTER_LATER") do
            puts "LATER_RAN=\#{test_database.connection.exec("SELECT 1").getvalue(0, 0)}"
          end
        end
      RUBY
      out, status = run_child_spec(source)

      expect(status).not_to be_success
      expect(out).to include("2 examples, 1 failure"), out
      expect(out).to include("# an undroppable database marks it")
      expect(out).to include("cannot drop a template database")
      expect(child_value(out, "AFTER_MARKED")).to eq("1"), out
      expect(child_value(out, "LATER_RAN")).to eq("1"), out
      expect(child_value(out, "AFTER_LATER")).to eq("1"), out
    end

    # A forked child that exits normally ends the parent's sessions, so the
    # harness's DROP fails. That example should fail with a message that
    # names the likely cause, and the next example should start clean.
    it "fails only the example whose drop failed, and says the connection was lost" do
      source = <<~RUBY
        #{prelude}
        #{watch}
        RSpec.describe "a fork that exits normally", order: :defined do
          it("forks", key: "AFTER_BROKEN") do
            test_database
            racetrack_and_arena
            $stdout.flush
            Process.wait(fork {})
          end

          it("runs next", key: "AFTER_NEXT") do
            puts "NEXT_RAN=\#{test_database.connection.exec("SELECT 1").getvalue(0, 0)}"
          end
        end
      RUBY
      out, status = run_child_spec(source)

      expect(status).not_to be_success
      expect(out).to include("2 examples, 1 failure"), out
      expect(out).to include("# a fork that exits normally forks")
      expect(out).to include("TestPostgres::ConnectionLost")
      expect(out).to include("if this spec forked, the child must end with exit!")
      expect(out).to match(/Caused by:.*PG::ConnectionBad/m)
      # The first drop fails and that database is forgotten. The other two
      # are still dropped, and so is the next example's.
      expect(child_value(out, "AFTER_BROKEN")).to eq("1"), out
      expect(child_value(out, "NEXT_RAN")).to eq("1"), out
      expect(child_value(out, "AFTER_NEXT")).to eq("1"), out
    end

    # The harness's comment says a spec that forks after using a database
    # must end the child with `exit!`. This is that case.
    it "keeps the container and the example's connection when a forked child ends with exit!" do
      source = <<~RUBY
        #{prelude}
        RSpec.describe "forking" do
          it("forks") do
            conn = test_database.connection
            conn.exec("SELECT 1")
            Process.wait(fork { exit!(7) })
            puts "CHILD_STATUS=\#{$?.exitstatus}"
            running, = Open3.capture2("docker", "ps", "-q", "--no-trunc", "--filter", "id=\#{TestPostgres.server.container_id}")
            puts "RUNNING=\#{running.strip == TestPostgres.server.container_id}"
            puts "QUERY=\#{conn.exec("SELECT 1").getvalue(0, 0)}"
          end
        end
      RUBY
      out, status = run_child_spec(source)

      expect(child_value(out, "CHILD_STATUS")).to eq("7"), out
      expect(child_value(out, "RUNNING")).to eq("true"), out
      expect(child_value(out, "QUERY")).to eq("1"), out
      expect(status).to be_success, out
    end

    # A child forked from the spec process runs the same at_exit hooks when
    # it exits normally, and only the process that started a container may
    # remove it. The harness never connects to the container here, so the
    # child can exit normally without closing a connection it shares.
    it "leaves a container to the process that started it when a forked child exits normally" do
      source = <<~RUBY
        require #{File.join(REPO_ROOT, "spec", "support", "test_postgres").inspect}
        RSpec.describe "a fork" do
          it("forks") do
            id = TestPostgres.docker("create", "--label", "\#{TestPostgres::LABEL}=1",
                                     "--label", "\#{TestPostgres::OWNER_LABEL}=\#{Process.pid}", TestPostgres.image_tag)
            TestPostgres.remove_at_exit(id)
            puts "CREATED=\#{id}"
            $stdout.flush
            Process.wait(fork { puts "CHILD_RAN=true" })
            puts "CHILD_STATUS=\#{$?.exitstatus}"
            puts "KEPT=\#{TestPostgres.docker("ps", "-a", "-q", "--no-trunc", "--filter", "id=\#{id}") == id}"
          end
        end
      RUBY
      out, status = run_child_spec(source)
      created = child_value(out, "CREATED")

      expect(status).to be_success, out
      expect(created).to match(/\A\h{64}\z/)
      expect(child_value(out, "CHILD_RAN")).to eq("true")
      expect(child_value(out, "CHILD_STATUS")).to eq("0")
      expect(child_value(out, "KEPT")).to eq("true"), out
      expect(docker_ids("id=#{created}")).to be_empty
    ensure
      Open3.capture2e("docker", "rm", "-f", "-v", created) if created
    end

    describe "when a launch fails" do
      # A stand-in for the docker command that logs every call and then runs
      # the real one, except that `docker port` does what `port_script` says.
      # Faking it here, at the edge, is how these make a launch fail partway.
      def with_fake_docker(port_script)
        Dir.mktmpdir do |dir|
          log = File.join(dir, "calls.log")
          File.write(File.join(dir, "docker"), <<~SH, perm: 0o755)
            #!/bin/sh
            echo "$1" >> #{log}
            if [ "$1" = port ]; then #{port_script}; fi
            exec #{real_docker} "$@"
          SH
          yield({ "PATH" => "#{dir}#{File::PATH_SEPARATOR}#{ENV.fetch("PATH")}" }, log)
        end
      end

      def real_docker
        ENV.fetch("PATH").split(File::PATH_SEPARATOR).map { |d| File.join(d, "docker") }.find { |f| File.executable?(f) }
      end

      let(:source) do
        <<~RUBY
          #{prelude}
          RSpec.describe "a broken launch" do
            it("one") { puts "PID=\#{Process.pid}"; test_database }
            it("two") { test_database }
          end
        RUBY
      end

      it "tries once, fails every example with the same error, and leaves no container behind" do
        with_fake_docker('echo "planted port failure" >&2; exit 1') do |env, log|
          out, status = run_child_spec(source, env: env)

          expect(status).not_to be_success
          expect(out).to include("2 examples, 2 failures")
          expect(out.scan("docker port failed: planted port failure").size).to eq(2)
          expect(File.readlines(log, chomp: true).count("run")).to eq(1)
          expect(docker_ids("label=#{TestPostgres::OWNER_LABEL}=#{child_value(out, "PID")}")).to be_empty
        end
      end

      it "says what the container logged when Postgres never gets ready" do
        with_fake_docker('echo "127.0.0.1:1"; exit 0') do |env, _log|
          out, status = run_child_spec(source, env: env.merge("QUAACK_TEST_PG_READY_TIMEOUT" => "3"))

          expect(status).not_to be_success
          expect(out).to include("wasn't ready after 3s")
          expect(out).to match(/Its last log lines:.*database system/m)
        end
      end
    end
  end
end
