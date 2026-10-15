# frozen_string_literal: true

# Holds a backend partway through one statement, so a cancel from a second
# session lands on that statement and no other (task 20261008-60).
#
# Postgres drops a cancel that arrives while a backend waits for its next
# command, and BEGIN and ROLLBACK leave almost no time to land one while
# they run. But a backend with log_statement = 'all' logs each statement
# after it reports it in pg_stat_activity and before it runs it, and with
# logging_collector on, that log line goes down a pipe to the logger process.
# So stall stops the logger and fills its pipe to the last byte, and the
# next statement any backend logs blocks in its write. cancel_when_logging
# waits until the backend shows that statement running and blocked in the
# pipe, cancels it, and lets the logger drain the pipe. The backend then
# finishes its write and finds the cancel before the statement runs.
#
# The server must be one of the spec's own (TestPostgres.extra_server),
# started with logging_collector=on, so stalling its logger stalls no one
# else. The container's postmaster is pid 1, and its stderr is the logger's
# pipe. Only its own user may open that, so every docker exec runs as
# postgres.
class StalledLogger
  # Fills the pipe in nonblocking writes, the last ones one byte each, until
  # it's full, so no log line of any size fits.
  FILL = <<~PERL
    use Fcntl;
    sysopen(my $pipe, "/proc/1/fd/2", O_WRONLY | O_NONBLOCK) or die "open: $!";
    1 while defined syswrite($pipe, "x" x 4096);
    1 while defined syswrite($pipe, "x");
  PERL

  WAIT_SECONDS = 10

  def initialize(server)
    @server = server
    @logger = shell("pgrep -f '^postgres: logger'").strip
    raise "no logger process; start the server with logging_collector=on" if @logger.empty?
  end

  def stall
    shell("kill -STOP #{@logger}")
    TestPostgres.docker("exec", "-u", "postgres", @server.container_id, "perl", "-e", FILL)
  end

  # In a thread, since the backend's own client is blocked until it's done.
  # Its value is the backend's kernel wait channel when the cancel went out,
  # "pipe_write" when it was held in its log line, so the cancel couldn't
  # have missed the statement.
  def cancel_when_logging(pid, statement)
    Thread.new do
      admin = PG.connect(host: @server.host, port: @server.port, dbname: "postgres",
                         user: TestPostgres::USER, password: TestPostgres::PASSWORD)
      wait_for(admin, pid, statement)
      wchan(pid).tap { admin.exec_params("SELECT pg_cancel_backend($1)", [pid]) }
    ensure
      admin&.close
      resume
    end
  end

  def resume = shell("kill -CONT #{@logger}")

  private

  def wait_for(admin, pid, statement)
    deadline = now + WAIT_SECONDS
    until running?(admin, pid, statement) && wchan(pid) == "pipe_write"
      raise "backend #{pid} never blocked logging #{statement}" if now > deadline

      sleep 0.02
    end
  end

  def running?(admin, pid, statement)
    admin.exec_params("SELECT FROM pg_stat_activity WHERE pid = $1 AND state = 'active' AND query = $2",
                      [pid, statement]).ntuples == 1
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  def wchan(pid) = shell("cat /proc/#{pid}/wchan").strip

  def shell(command) = TestPostgres.docker("exec", "-u", "postgres", @server.container_id, "sh", "-c", command)
end
