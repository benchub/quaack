# frozen_string_literal: true

# Helpers for specs of the timeout checks that read the server's clock
# (Quaack::Enclave::ServerClock), shared by RunDiscipline, ArenaRunner, and
# ProductionComparison's specs.
module ServerClockHelpers
  # Models a jump server whose clock runs at half the server's rate, as
  # clock slewing can make it, a little, for real: statement_timeout fires on
  # the server's clock, so the enclave's can't tell a timeout from a cancel.
  def slow_enclave_clock
    base = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
    allow(Process).to receive(:clock_gettime).and_wrap_original do |original, id, unit = :float_second|
      next original.call(id, unit) unless id == Process::CLOCK_MONOTONIC && unit == :millisecond

      (base + ((original.call(id, :float_millisecond) - base) / 2)).floor
    end
  end

  # Cancels conn's statement from a second session once pg_stat_activity
  # shows it in pg_sleep, so the cancel can't land while conn is idle and
  # get dropped. Runs the block meanwhile and returns its value. If the
  # block succeeds, it waits for the canceller and raises whatever the
  # canceller raised. If the block fails, its failure is the one reported:
  # the canceller is stopped, and whatever it raised, such as its own wait
  # running out because the code under test never slept, is dropped.
  def cancel_when_sleeping(conn)
    other = PG.connect(conn.conninfo_hash.compact.except(:fallback_application_name))
    canceller = start_canceller(other, conn.backend_pid)
    value = yield
    canceller.join
    value
  ensure
    stop_canceller(canceller)
    other&.close
  end

  def start_canceller(other, pid)
    Thread.new do
      Thread.current.report_on_exception = false
      wait_until_sleeping(other, pid)
      other.exec_params("SELECT pg_cancel_backend($1)", [pid])
    end
  end

  def stop_canceller(canceller)
    return unless canceller

    canceller.kill
    begin
      canceller.join
    rescue StandardError
      nil
    end
  end

  # Models a connection whose read of the server's clock after a cancel
  # fails, as when the connection drops, raising a Postgres error that
  # carries message.
  def clockless_after_cancel(conn, message)
    Class.new(SimpleDelegator) do
      define_method(:exec) do |sql, *args, &block|
        raise PG::ConnectionBad, message if sql.include?("ROLLBACK TO SAVEPOINT")

        __getobj__.exec(sql, *args, &block)
      end
    end.new(conn)
  end

  # Models a bug in the enclave's own read of the server's clock: the exec
  # whose SQL includes trigger reads something that isn't a clock, so
  # parsing it fails.
  def misread_clock(conn, trigger)
    Class.new(SimpleDelegator) do
      define_method(:exec) do |sql, *args, &block|
        sql = sql.sub(Quaack::Enclave::ServerClock::NOW_SQL, "SELECT 'not a clock'") if sql.include?(trigger)
        __getobj__.exec(sql, *args, &block)
      end
    end.new(conn)
  end

  def wait_until_sleeping(other, pid)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until other.exec_params(
      "SELECT count(*) FROM pg_stat_activity WHERE pid = $1 AND wait_event = 'PgSleep'", [pid]
    ).getvalue(0, 0) == "1"
      raise "the statement never reached pg_sleep" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
  end
end

RSpec.configure { it.include ServerClockHelpers }
