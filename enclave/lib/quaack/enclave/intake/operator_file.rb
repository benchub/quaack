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
        # symlink, or anything but a regular file, or can't be read, with a
        # fixed reason that says which, and <kind>_too_large past MAX_BYTES.
        #
        # NOFOLLOW refuses a symlink as the path's last part only. A symlink
        # in a parent directory is followed, which the threat model allows:
        # the operator chooses the path. NONBLOCK keeps
        # opening a FIFO from waiting for a writer; a FIFO then fails the
        # regular file check. Checking the open file, not the path, means
        # the check and the read see the same file.
        def read(path, kind)
          path = expand_home(path)
          File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK | File::BINARY) do |file|
            unreadable(kind, "not_regular_file") unless file.stat.file?

            contents(file, kind)
          end
        rescue SystemCallError, IOError => e
          unreadable(kind, reason(path, e))
        end

        def contents(file, kind)
          text = file.read(MAX_BYTES + 1) || +""
          raise Error, "#{kind}_too_large" if text.bytesize > MAX_BYTES

          text
        end

        def expand_home(path)
          return Dir.home if path == "~"
          return File.join(Dir.home, path.delete_prefix("~/")) if path.start_with?("~/")

          path
        end

        def reason(path, error)
          return "missing" if error.is_a?(Errno::ENOENT) || error.is_a?(Errno::ENOTDIR)
          return "permission_denied" if error.is_a?(Errno::EACCES) || error.is_a?(Errno::EPERM)
          return "symlink" if symlink?(path)

          "not_regular_file"
        end

        def symlink?(path)
          File.lstat(path).symlink?
        rescue SystemCallError, IOError
          false
        end

        def unreadable(kind, reason)
          raise Error.new("#{kind}_unreadable", reason:), cause: nil
        end
      end
    end
  end
end
