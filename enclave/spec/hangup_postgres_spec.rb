# frozen_string_literal: true

require "open3"

# When the driver goes away mid-step (its ssh session drops, or its
# timeout fires), quaacks cancels the running query, which rolls back its
# transaction, and exits nonzero (README, "Where QUAACK runs"). The driver
# closes stdin as soon as it has written the input, so stdin closing is
# normal. What counts as a hangup is SIGHUP, or the reader of stdout going
# away.
RSpec.describe "quaacks on hangup" do
  let(:marker) { "hangup_marker_7c1f" }

  # CLI.main with a step that opens a registered connection, creates a
  # table in a transaction, and sleeps in Postgres.
  def script
    <<~RUBY
      require "pg"
      require "quaack/enclave"
      cli = Quaack::Enclave::CLI
      handler = lambda do |**|
        c = Quaack::Enclave::Connections.register(PG.connect(**#{test_database.connection_params.inspect}))
        c.exec("BEGIN")
        c.exec("CREATE TABLE #{marker} (x int)")
        c.exec("SELECT pg_sleep(60) /* #{marker} */")
        [{ type: :version, version: "1" }]
      end
      exit cli.main(ARGV, steps: { "probe" => cli::Step.new(handler:) })
    RUBY
  end

  # Starts script in a child, the way the driver does, and waits until its
  # query is running.
  def start_sleeping_step
    stdin, stdout, waiter = Open3.popen2(RbConfig.ruby, "-I", File.join(GEM_ROOT, "lib"), "-e", script, "probe")
    stdin.close
    raise "the step's query never started" unless true_within?(10) { sleeping_backends.positive? }

    [stdout, waiter]
  end

  def sleeping_backends
    test_database.connection.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND query LIKE $1",
      ["%pg_sleep(60) /* #{marker}%"]
    ).getvalue(0, 0).to_i
  end

  def marker_table = test_database.connection.exec_params("SELECT to_regclass($1)", [marker]).getvalue(0, 0)

  # Whether the block turns true within seconds.
  def true_within?(seconds)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    true
  end

  def expect_stopped_and_rolled_back(waiter)
    expect_stopped(waiter)
    expect(true_within?(3) { sleeping_backends.zero? }).to be(true), "the query was still running"
    expect(marker_table).to be_nil
  end

  def expect_stopped(waiter)
    expect(waiter.join(5)).not_to be_nil, "quaacks was still running 5s after the hangup"
    expect(waiter.value.success?).not_to be(true) # a nonzero status, or death by signal
  ensure
    Process.kill("KILL", waiter.pid) if waiter.alive?
  end

  it "cancels the running query, rolls back, and exits nonzero when stdout's reader goes away" do
    stdout, waiter = start_sleeping_step
    stdout.close

    expect_stopped_and_rolled_back(waiter)
  end

  it "cancels the running query, rolls back, and exits nonzero on SIGHUP" do
    stdout, waiter = start_sleeping_step
    Process.kill("HUP", waiter.pid)

    expect_stopped_and_rolled_back(waiter)
    stdout.close
  end
end
