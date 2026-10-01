# frozen_string_literal: true

module Quaack
  module Driver
    # Progress lines for `quaack run`, on stderr. Lines carry only step
    # names, counts, and timings, never data from the enclave.
    #
    #   progress = Progress.new(io: $stderr, total: 18)
    #   progress.step("5a-5", "generator three (LLM)") { ... }
    #   # quaack: [2/18] 5a-5 generator three (LLM)
    #   # quaack: [2/18] 5a-5 still running (30s)      every interval
    #   # quaack: [2/18] 5a-5 done in 42s               or "failed after 42s"
    #   progress.skip("index-search")
    #   # quaack: [1/18] index-search: already done, skipping
    #
    # note prints a line under the current step, such as an LLM ask, and
    # within(prefix) gives the same interface for a step's sub-steps, as
    # notes. clock answers seconds and interval is the heartbeat's period,
    # so specs pass a fake clock and a short interval.
    class Progress
      MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

      def initialize(io:, total:, clock: MONOTONIC, interval: 30)
        @io = io
        @total = total
        @clock = clock
        @interval = interval
        @number = 0
        @lock = Mutex.new
      end

      # Runs the block as the next step and returns what it returns.
      def step(name, description, &)
        @number += 1
        say("#{name} #{description}")
        start = @clock.call
        result = heartbeat(name, start, &)
        say("#{name} done in #{since(start)}")
        result
      rescue StandardError, Interrupt
        say("#{name} failed after #{since(start)}")
        raise
      end

      def skip(name)
        @number += 1
        say("#{name}: already done, skipping")
      end

      def note(text) = say(text)

      def within(prefix) = Within.new(self, prefix)

      # seconds as 42s, 1m30s, or 1h02m05s.
      def self.duration(seconds)
        seconds = seconds.to_i
        hours, rest = seconds.divmod(3600)
        minutes, secs = rest.divmod(60)
        return "#{hours}h#{format("%<m>02dm%<s>02ds", m: minutes, s: secs)}" if hours.positive?
        return "#{minutes}m#{format("%<s>02ds", s: secs)}" if minutes.positive?

        "#{secs}s"
      end

      def since(start) = self.class.duration(@clock.call - start)

      def say(text)
        @lock.synchronize { @io.print("quaack: [#{@number}/#{@total}] #{text}\n") }
      end

      # Runs the block while a thread prints a still-running line every
      # interval. The thread is stopped and joined however the block ends.
      def heartbeat(name, start)
        stop = Queue.new
        timer = Thread.new do
          say("#{name} still running (#{since(start)})") while stop.pop(timeout: @interval).nil?
        end
        yield
      ensure
        stop&.push(:stop)
        timer&.join
      end

      private :since, :say, :heartbeat

      # A step's sub-steps, printed as notes under it.
      class Within
        def initialize(progress, prefix)
          @progress = progress
          @prefix = prefix
        end

        def step(name, _description = nil)
          @progress.note("#{@prefix} #{name}")
          yield
        end

        def skip(name) = @progress.note("#{@prefix} #{name}: already done, skipping")

        def note(text) = @progress.note(text)

        def within(prefix) = Within.new(@progress, "#{@prefix} #{prefix}")
      end

      # Prints nothing, for callers with no progress to show.
      module Null
        module_function

        def step(*) = yield

        def skip(*) = nil

        def note(*) = nil

        def within(*) = self
      end

      NULL = Null
    end
  end
end
