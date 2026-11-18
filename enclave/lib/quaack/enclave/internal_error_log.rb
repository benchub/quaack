# frozen_string_literal: true

require "fcntl"

module Quaack
  module Enclave
    # A local record, on the jump server, of what caused an internal_error
    # (20261020-5). ErrorFilter sends only the rule, and stderr goes to the
    # null device, so without this nothing keeps the cause. Each line holds
    # the time, the step, the exception's class name, and the gem-relative
    # file and line of its first backtrace location inside this gem:
    #
    #   2026-11-18T12:30:05Z step=redact-rewrite class=KeyError at=quaack/enclave/redaction.rb:42
    #
    # It never writes the message, which can hold a value, or a backtrace
    # location outside the gem, whose path can. A field that isn't plain is
    # written as none. The file lives in the run's directory, mode 0600 like
    # the store's entries, and stops growing at MAX_BYTES. It never follows a
    # symlink at its name, and never raises.
    module InternalErrorLog
      FILE_NAME = "internal_errors.log"
      MAX_BYTES = 64 * 1024
      # This gem's lib directory, which every location written is under.
      GEM_LIB = File.expand_path("../..", __dir__)
      STEP = /\A[a-z0-9][a-z0-9_-]{0,62}\z/
      CLASS_NAME = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/
      NONE = "none"

      module_function

      def append(dir, step:, exception:, now: Time.now)
        File.open(File.join(dir, FILE_NAME), File::WRONLY | File::APPEND | File::CREAT | File::NOFOLLOW, 0o600) do |f|
          f.chmod(0o600)
          f.write(line(step, exception, now)) if f.size < MAX_BYTES
        end
        nil
      rescue SignalException
        raise
      rescue Exception # rubocop:disable Lint/RescueException
        nil
      end

      def line(step, exception, now)
        "#{now.utc.strftime("%FT%TZ")} step=#{plain(step, STEP)} " \
          "class=#{plain(exception.class.name, CLASS_NAME)} at=#{location(exception)}\n"
      end

      def plain(value, pattern)
        value.instance_of?(String) && value.ascii_only? && value.match?(pattern) ? value : NONE
      end

      # The first backtrace line under GEM_LIB, as path:line relative to it.
      def location(exception)
        prefix = "#{GEM_LIB}/"
        (exception.backtrace || []).each do |entry|
          match = /\A(?<path>[^:]+):(?<line>\d+):/.match(entry)
          next unless match && match[:path].start_with?(prefix)

          relative = match[:path].delete_prefix(prefix)
          return "#{relative}:#{match[:line]}" if relative.match?(%r{\A[a-z0-9_/]+\.rb\z})
        end
        NONE
      end
    end
  end
end
