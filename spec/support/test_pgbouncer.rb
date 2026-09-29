# frozen_string_literal: true

# See spec/support/test_postgres.rb, which loads this, and
# TestPostgres::Server#pgbouncer_port.
module TestPostgres
  # PgBouncer in session mode, in the server's container. It reaches
  # Postgres on its Unix socket, which the image trusts, and asks its own
  # clients for the harness's password. Any database name passes through to
  # the server's.
  module PgBouncer
    DIR = "/tmp/pgbouncer"
    PORT = 6432
    CONFIG = <<~INI.freeze
      [databases]
      * = host=/var/run/postgresql port=5432

      [pgbouncer]
      listen_addr = 0.0.0.0
      listen_port = #{PORT}
      unix_socket_dir =
      auth_type = scram-sha-256
      auth_file = #{DIR}/userlist.txt
      pidfile = #{DIR}/pgbouncer.pid
      logfile = #{DIR}/pgbouncer.log
      pool_mode = session
      min_pool_size = 0
      default_pool_size = 100
      max_client_conn = 200
    INI

    module_function

    # Returns its port on the host. It won't run as root, so it runs as
    # postgres, in the background (-d).
    def start(container_id)
      write(container_id, "pgbouncer.ini", CONFIG)
      write(container_id, "userlist.txt", %("#{USER}" "#{PASSWORD}"\n))
      TestPostgres.docker("exec", "-u", "postgres", container_id, "pgbouncer", "-d", "#{DIR}/pgbouncer.ini")
      wait_until_ready(container_id)
      Integer(TestPostgres.docker("port", container_id, "#{PORT}/tcp").lines.first.strip.split(":").last)
    end

    # pg_isready stops at PgBouncer's password request, so it opens no
    # server backend, which a spec would see as another client.
    def wait_until_ready(container_id)
      deadline = now + READY_TIMEOUT
      until system("docker", "exec", container_id, "pg_isready", "-q", "-h", "127.0.0.1", "-p", PORT.to_s,
                   "-U", USER, "-d", "postgres", out: File::NULL, err: File::NULL)
        raise "PgBouncer in #{container_id} wasn't ready after #{READY_TIMEOUT}s" if now > deadline

        sleep 0.1
      end
    end

    def write(container_id, name, text)
      TestPostgres.docker("exec", "-i", "-u", "postgres", container_id, "sh", "-c",
                          "mkdir -p #{DIR} && cat > #{DIR}/#{name}", stdin_data: text)
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
