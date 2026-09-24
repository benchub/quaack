# frozen_string_literal: true

require "digest"
require "open3"
require "pg"

# Throwaway Postgres for the test suites. Any suite can load it:
#
#   require_relative "../../spec/support/test_postgres"
#   RSpec.configure { |config| TestPostgres.configure(config) }
#
# Then an example calls `test_database` for a fresh copy of the sample
# schema and data, or `racetrack_and_arena` for two databases on one server,
# the way the real run server has them. Each example gets its own databases,
# and they're dropped after it.
#
# The first example that asks for a database starts one container for the
# whole spec process: Postgres 18 with HypoPG, built from postgres/Dockerfile.
# It's removed when the process exits. Every container carries LABEL and the
# owning process's pid in OWNER_LABEL, so one left behind by a crashed run
# can be found with `docker ps -a --filter label=quaack.test-postgres`. The
# next run removes any whose owner is gone.
#
# There's no fallback. If Docker isn't running, every example that asks for
# a database fails with DockerUnavailable. None are skipped.
#
# A spec must not fork after it has used a database, or the forked child
# must end with `exit!`. The child shares the parent's sockets. If it exits
# normally, it closes its copies of the parent's connections, and that ends
# the parent's sessions too. `exit!` skips that, along with the at_exit hooks.
module TestPostgres
  class DockerUnavailable < StandardError; end
  class ConnectionLost < StandardError; end

  LABEL = "quaack.test-postgres"
  OWNER_LABEL = "quaack.test-postgres.owner-pid"
  DIR = File.join(__dir__, "postgres")
  USER = "postgres"
  PASSWORD = "quaack-test"
  # Seconds to wait for Postgres to take connections. The environment
  # variable is there so a spec can test the timeout without a long wait.
  READY_TIMEOUT = Integer(ENV.fetch("QUAACK_TEST_PG_READY_TIMEOUT", "60"))
  # The racetrack template gets the sample rows and ANALYZE. The arena
  # template gets only the schema, since arena starts empty.
  RACETRACK_TEMPLATE = "quaack_racetrack_template"
  ARENA_TEMPLATE = "quaack_arena_template"
  # autovacuum is off, as on the real run server, so a background ANALYZE
  # can't change the statistics a test sees. The rest trade durability,
  # which a throwaway database doesn't need, for speed.
  SERVER_SETTINGS = %w[autovacuum=off fsync=off synchronous_commit=off full_page_writes=off].freeze

  # One database on the test server. `connection` opens a connection on
  # first use and keeps it; `connect` opens a new one each time. Dropping
  # the database closes the kept one and forces any others off.
  class Database
    attr_reader :name, :host, :port

    def initialize(name, host, port)
      @name = name
      @host = host
      @port = port
    end

    def connection_params = { host: host, port: port, dbname: name, user: USER, password: PASSWORD }
    def connect = PG.connect(**connection_params)
    def connection = @connection ||= connect

    def close
      @connection&.close
      @connection = nil
    end
  end

  RunServer = Data.define(:racetrack, :arena)

  # The one container for this process, and an admin connection to its
  # `postgres` database for creating and dropping the others.
  class Server
    attr_reader :container_id, :host, :port

    # Docker picked the host port, so this reads it back.
    def initialize(container_id)
      @container_id = container_id
      @host, port = TestPostgres.docker("port", container_id, "5432/tcp").lines.first.strip.split(":")
      @port = Integer(port)
      @created = []
      @counter = 0
    end

    def admin = @admin ||= PG.connect(host: host, port: port, dbname: "postgres", user: USER, password: PASSWORD)

    def database_names = admin.exec("SELECT datname FROM pg_database").column_values(0)

    # Polls with a real connection until one works. While the image's entry
    # point initializes the cluster, Postgres listens only on its Unix
    # socket, so a TCP connection fails until the real server is up.
    def wait_until_ready
      deadline = now + READY_TIMEOUT
      begin
        admin
      rescue PG::ConnectionBad => e
        raise not_ready(e) if now > deadline

        sleep 0.1
        retry
      end
    end

    def build_templates
      create_template(ARENA_TEMPLATE, "template1") { |conn| conn.exec(File.read(File.join(DIR, "schema.sql"))) }
      create_template(RACETRACK_TEMPLATE, ARENA_TEMPLATE) do |conn|
        conn.exec(File.read(File.join(DIR, "data.sql")))
        conn.exec("VACUUM ANALYZE")
      end
    end

    def create_database(template)
      @counter += 1
      db = Database.new("quaack_test_#{Process.pid}_#{@counter}", host, port)
      admin.exec("CREATE DATABASE #{db.name} TEMPLATE #{template}")
      @created << db
      db
    end

    # Tries every drop, then raises the first error. The databases are
    # forgotten either way, so one failed drop fails only its own example,
    # not every one after it.
    def drop_databases
      error = @created.map { |db| drop(db) }.compact.first
      raise error if error
    ensure
      @created.clear
    end

    private

    # Returns the error, if any, rather than raising it. A lost connection
    # is closed and forgotten, so the next use of `admin` opens a new one.
    def drop(db)
      db.close
      admin.exec("DROP DATABASE IF EXISTS #{db.name} WITH (FORCE)")
      nil
    rescue PG::ConnectionBad
      @admin&.close
      @admin = nil
      connection_lost(db)
    rescue PG::Error => e
      e
    end

    # Called from a rescue, so raising here makes the PG error the cause.
    def connection_lost(db)
      raise ConnectionLost, "The harness's connection to Postgres was lost while dropping #{db.name}; " \
                            "if this spec forked, the child must end with exit! " \
                            "(see the comment at the top of spec/support/test_postgres.rb)."
    rescue ConnectionLost => e
      e
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Postgres logs to stderr, so this reads both streams.
    def not_ready(error)
      logs, = Open3.capture2e("docker", "logs", "--tail", "20", container_id)
      "Postgres in #{container_id} wasn't ready after #{READY_TIMEOUT}s: #{error.message.strip}\n" \
        "Its last log lines:\n#{logs}"
    end

    # Nothing may be connected to a template when it's copied, so the
    # connection that loads it is closed before anyone uses it.
    def create_template(name, from)
      admin.exec("CREATE DATABASE #{name} TEMPLATE #{from}")
      db = Database.new(name, host, port)
      yield db.connection
    ensure
      db&.close
    end
  end

  module_function

  def docker(*args)
    out, err, status = Open3.capture3("docker", *args)
    raise "docker #{args.first} failed: #{err.strip}" unless status.success?

    out.strip
  rescue Errno::ENOENT
    raise DockerUnavailable, "TestPostgres needs Docker, and there's no docker command on PATH."
  end

  def check_docker
    docker("info", "--format", "{{.ServerVersion}}")
  rescue RuntimeError => e
    raise DockerUnavailable, "TestPostgres needs Docker, and the Docker daemon isn't reachable: #{e.message}"
  end

  # Tagged with a hash of the Dockerfile, so an edit gets a new tag and a
  # rebuild, and an unchanged one reuses the image already built.
  def image_tag(dir = DIR)
    "quaack-test-postgres:#{Digest::SHA256.file(File.join(dir, "Dockerfile")).hexdigest[0, 12]}"
  end

  def build_image
    docker("image", "inspect", image_tag)
  rescue RuntimeError
    docker("build", "-q", "-t", image_tag, DIR)
  end

  # Removes containers whose owning process is gone. A container whose owner
  # is still running belongs to another spec process, maybe in another
  # worktree, so it stays.
  def remove_stale_containers
    docker("ps", "-a", "--filter", "label=#{LABEL}", "--format", "{{.ID}} {{.Label \"#{OWNER_LABEL}\"}}")
      .lines.map(&:split).each do |id, pid|
        docker("rm", "-f", "-v", id) unless process_alive?(Integer(pid.to_s, exception: false))
      end
  end

  def process_alive?(pid)
    return false unless pid&.positive?

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def start_container(settings = SERVER_SETTINGS)
    docker("run", "-d", "--label", "#{LABEL}=1", "--label", "#{OWNER_LABEL}=#{Process.pid}",
           "--tmpfs", "/var/lib/postgresql", "-e", "POSTGRES_PASSWORD=#{PASSWORD}",
           "-p", "127.0.0.1::5432", image_tag, *settings.flat_map { |s| ["-c", s] })
  end

  # A launch that fails isn't tried again. Every later example gets the same
  # error, rather than another build, another 60-second wait, and another
  # container.
  def server
    raise @launch_error if @launch_error

    @server ||= launch
  rescue StandardError => e
    @launch_error ||= e
    raise
  end

  def launch
    check_docker
    remove_stale_containers
    build_image
    id = start_container
    remove_at_exit(id)
    started = Server.new(id)
    started.wait_until_ready
    started.build_templates
    started
  end

  # Registered as soon as the container exists, so it's removed even if
  # nothing after this works. Only the process that started it removes it:
  # a process forked from it runs the same at_exit hooks when it exits.
  def remove_at_exit(id)
    owner = Process.pid
    at_exit { docker("rm", "-f", "-v", id) if Process.pid == owner }
  end

  # A server of its own, started with settings in place of SERVER_SETTINGS,
  # for the rare spec that needs a server-wide setting the shared server
  # can't change, such as autovacuum: a -c setting outranks ALTER SYSTEM.
  # It has no templates, so use its admin connection. The spec removes it
  # with remove_server, in an ensure. One a crash leaves behind carries
  # LABEL, so the next run removes it.
  def extra_server(settings)
    server
    Server.new(start_container(settings)).tap(&:wait_until_ready)
  end

  def remove_server(extra)
    extra.admin.close
    docker("rm", "-f", "-v", extra.container_id)
  end

  def create_database = server.create_database(RACETRACK_TEMPLATE)

  def create_run_server
    RunServer.new(racetrack: server.create_database(RACETRACK_TEMPLATE),
                  arena: server.create_database(ARENA_TEMPLATE))
  end

  # Drops every database created since the last call. Does nothing, and
  # starts nothing, if no example has asked for a database yet.
  def drop_databases
    @server&.drop_databases
  end

  module Helpers
    def test_database = @test_database ||= TestPostgres.create_database
    def racetrack_and_arena = @racetrack_and_arena ||= TestPostgres.create_run_server
  end

  def configure(config)
    config.include Helpers
    config.after { TestPostgres.drop_databases }
  end
end
