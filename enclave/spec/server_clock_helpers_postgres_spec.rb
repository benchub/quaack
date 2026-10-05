# frozen_string_literal: true

require_relative "support/server_clock"

# The spec helper that cancels a statement from a second session.
RSpec.describe ServerClockHelpers do
  let(:conn) { racetrack_and_arena.racetrack.connection }

  describe "#cancel_when_sleeping" do
    it "cancels the statement once it sleeps, and returns the block's value" do
      value = cancel_when_sleeping(conn) do
        expect { conn.exec("SELECT pg_sleep(3)") }.to raise_error(PG::QueryCanceled, /user request/)
        :done
      end
      expect(value).to eq(:done)
    end

    it "reports the block's own failure, at once, when the statement never sleeps" do
      threads = Thread.list
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { cancel_when_sleeping(conn) { raise "the code under test failed" } }
        .to raise_error(RuntimeError, "the code under test failed")
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).to be < 5
      expect(Thread.list - threads).to eq([])
    end

    # Its failure means the statement wasn't cancelled as the spec meant,
    # so a block that passes anyway mustn't hide it.
    it "reports the canceller's own failure when the block succeeds" do
      allow(self).to receive(:wait_until_sleeping).and_wrap_original do
        sleep 0.2
        raise "the canceller failed"
      end
      threads = Thread.list
      expect { cancel_when_sleeping(conn) { :done } }.to raise_error(RuntimeError, "the canceller failed")
      expect(Thread.list - threads).to eq([])
    end
  end
end
