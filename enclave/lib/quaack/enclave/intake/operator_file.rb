# frozen_string_literal: true

require_relative "error"

module Quaack
  module Enclave
    module Intake
      # Reads one of the operator's input files on the jump server. The path
      # comes from argv, so it's the operator's own and fine to open, but a
      # path can hold anything, so it never goes into an error.
      module OperatorFile
        # Well past any query or plan intake takes.
        MAX_BYTES = 16 * 1024 * 1024

        module_function

        # The file's bytes, as a binary String. kind, "query" or "plan",
        # names the rules: <kind>_unreadable if the path is missing, a
        # symlink, or anything but a regular file, or can't be read, and
        # <kind>_too_large past MAX_BYTES.
        #
        # NOFOLLOW refuses a symlink as the path's last part only. A symlink
        # in a parent directory is followed, which the threat model allows:
        # the operator chooses the path. NONBLOCK keeps
        # opening a FIFO from waiting for a writer; a FIFO then fails the
        # regular file check. Checking the open file, not the path, means
        # the check and the read see the same file.
        def read(path, kind)
          File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK | File::BINARY) do |file|
            raise Error, "#{kind}_unreadable" unless file.stat.file?

            contents(file, kind)
          end
        rescue SystemCallError, IOError
          raise Error, "#{kind}_unreadable", cause: nil
        end

        def contents(file, kind)
          text = file.read(MAX_BYTES + 1) || +""
          raise Error, "#{kind}_too_large" if text.bytesize > MAX_BYTES

          text
        end
      end
    end
  end
end
