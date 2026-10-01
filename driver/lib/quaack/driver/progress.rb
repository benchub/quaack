# frozen_string_literal: true

module Quaack
  module Driver
    # Progress lines for `quaack run`, on stderr. Lines carry only step
    # names, counts, and timings, and redacted DDL the enclave already lets
    # out, never data from the enclave.
    #
    #   progress = Progress.new(io: $stderr, total: 18)
    #   progress.step("5a-5", "Asking the LLM for index ideas") { ... }
    #   # quaack: [2/18] Asking the LLM for index ideas (5a-5)
    #   # quaack: [2/18] Still working, 30s so far (5a-5)   every interval
    #   # quaack: [2/18] Done in 42s (5a-5)                 or "Failed after 42s"
    #   progress.skip("index-search", "Searching for indexes")
    #   # quaack: [1/18] Already done, skipping: Searching for indexes (index-search)
    #
    # Each line says in plain English what's happening, and ends with the
    # step's ID in parentheses.
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
        say("#{description} (#{name})")
        start = @clock.call
        result = heartbeat(name, start, &)
        say("Done in #{since(start)} (#{name})")
        result
      rescue StandardError, Interrupt
        say("Failed after #{since(start)} (#{name})")
        raise
      end

      def skip(name, description)
        @number += 1
        say("Already done, skipping: #{description} (#{name})")
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

      # Runs the block while a thread prints a still-working line every
      # interval. The thread is stopped and joined however the block ends.
      def heartbeat(name, start)
        stop = Queue.new
        timer = Thread.new do
          say("Still working, #{since(start)} so far (#{name})") while stop.pop(timeout: @interval).nil?
        end
        yield
      ensure
        stop&.push(:stop)
        timer&.join
      end

      private :since, :say, :heartbeat

      # A step's sub-steps, printed as notes under it, each after prefix,
      # such as "Rewrite 1".
      class Within
        def initialize(progress, prefix)
          @progress = progress
          @prefix = prefix
        end

        def step(name, description)
          @progress.note("#{@prefix}: #{description} (#{name})")
          yield
        end

        def skip(name, description) = @progress.note("#{@prefix}: Already done, skipping: #{description} (#{name})")

        def note(text) = @progress.note(text)

        def within(prefix) = Within.new(@progress, "#{@prefix}, #{prefix}")
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
