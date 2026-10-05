# frozen_string_literal: true

module Quaack
  module Enclave
    # A sampling profiler for quaacks on the jump server, where rbspy can't
    # attach to Ubuntu's packaged Ruby. With QUAACKS_PROFILE=<path> set,
    # CLI.main runs its step under during: a thread reads the step's
    # backtrace every 10 ms, and when the step ends, however it ends, the
    # count of each path:lineno is written to path, readable only by its
    # owner. Self counts the samples a line was running in; total, the
    # samples it was anywhere on the stack in, once a sample however deep it
    # recurses.
    #
    # It records code locations only, never a value, and writes only to
    # path, never to stdout or stderr. Failing to write the profile doesn't
    # fail the step.
    #
    # The sampler is a Ruby thread, so it runs only when it holds the GVL:
    # while the step waits on Postgres or I/O, every 10 ms or so, but while
    # the step is busy in Ruby, only at thread switches, about 7 times a
    # second. So the samples lean toward waits, but over a run of minutes
    # they still show where the Ruby CPU goes.
    module Profiler
      INTERVAL = 0.01

      module_function

      # Yields, sampling the calling thread if path is set, and returns the
      # block's value.
      def during(path)
        return yield if path.nil? || path.empty?

        counts = { samples: 0, own: Hash.new(0), total: Hash.new(0) }
        sampler = start(Thread.current, counts)
        begin
          yield
        ensure
          sampler.kill.join
          write(path, counts)
        end
      end

      def start(target, counts)
        Thread.new do
          Thread.current.report_on_exception = false
          loop do
            sleep INTERVAL
            locations = target.backtrace_locations
            break unless locations

            record(counts, locations.map { "#{it.absolute_path || it.path}:#{it.lineno}" })
          end
        end
      end

      def record(counts, lines)
        return if lines.empty?

        counts[:samples] += 1
        counts[:own][lines.first] += 1
        lines.uniq.each { counts[:total][it] += 1 }
      end

      def write(path, counts)
        File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(report(counts)) }
      rescue SystemCallError, IOError
        nil
      end

      def report(counts)
        header = "# quaacks profile: #{counts[:samples]} samples. self, total, location.\n"
        lines = counts[:total].sort_by { |line, total| [-total, -counts[:own][line], line] }
        header + lines.map { |line, total| "#{counts[:own][line]}\t#{total}\t#{line}\n" }.join
      end
    end
  end
end
