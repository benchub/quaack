# frozen_string_literal: true

require_relative "connections"

module Quaack
  module Enclave
    # What quaacks does when the driver goes away mid-step, as when its ssh
    # session drops or its timeout fires (DESIGN.md, "Where QUAACK runs"). It
    # cancels every registered connection's running statement (see
    # Connections.cancel_all), which aborts its transaction, and then dies
    # of SIGHUP. ErrorFilter.guard lets the SignalException through, so a
    # new run is deleted (see CLI#with_new_run) and the process ends by the
    # signal, never with a success status. Store entries are written only
    # after a step succeeds, so none is left half written.
    #
    # The driver closes stdin as soon as it has written the input, so stdin
    # closing is normal. A hangup is SIGHUP, or the reader of stdout going
    # away: a watcher thread waits for stdout to turn readable, which a
    # pipe's or socket's write end does only once the other end has closed.
    module Hangup
      module_function

      # Runs the block with hangups handled, and stops watching once it
      # returns. out is the real stdout.
      def during(out)
        previous = Signal.trap("HUP") { hang_up }
        watcher = Thread.new { watch(out) } if watchable?(out)
        yield
      ensure
        watcher&.kill
        Signal.trap("HUP", previous) if previous
      end

      # Only a pipe or socket turns readable when its reader goes away. A
      # regular file or a tty is readable at once, so watching one would
      # hang up every step.
      def watchable?(out)
        stat = out.stat
        stat.pipe? || stat.socket?
      rescue IOError, SystemCallError
        false
      end

      def hang_up
        Connections.cancel_all
        raise SignalException, "HUP"
      end

      def watch(out)
        # Not out.wait_readable, which refuses an IO opened only for writing.
        IO.select([out]) # rubocop:disable Lint/IncompatibleIoSelectWithFiberScheduler
        Process.kill("HUP", Process.pid)
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
