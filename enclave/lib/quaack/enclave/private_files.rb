# frozen_string_literal: true

require "fileutils"
require "securerandom"

module Quaack
  module Enclave
    # File operations for the governed store that keep what they make
    # private to the operator: directories 0700 and files 0600, whatever the
    # umask is. A mode goes through the umask when a file or directory is
    # made, and the umask can only take bits away, so nothing is ever more
    # open than it should be. A chmod right after puts back any owner bits
    # the umask took.
    #
    # No test can tell the creation mode from the chmod after it, since
    # both leave the same mode. The creation mode is still what keeps the
    # file or directory closed to others in the moment before the chmod.
    module PrivateFiles
      module_function

      # Makes dir, and each missing directory above it, mode 0700.
      def make_directories(dir)
        return if File.directory?(dir)

        make_directories(File.dirname(dir))
        make_directory(dir)
      end

      def make_directory(dir)
        Dir.mkdir(dir, 0o700)
        File.chmod(0o700, dir)
      end

      # Writes contents to a new temp file in file's directory, made 0600,
      # and renames it over file, so a reader never sees half a file. If
      # anything is already at the temp name, even a symlink, it fails and
      # leaves that alone: File::EXCL never follows a symlink. If a later
      # step fails, it removes the temp file it made and re-raises.
      def write_atomically(file, contents)
        temp = File.join(File.dirname(file), ".#{File.basename(file)}.#{SecureRandom.hex(8)}.tmp")
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
          fill_and_rename(f, contents, temp, file)
        end
      end

      def fill_and_rename(temp_file, contents, temp, file)
        temp_file.chmod(0o600)
        temp_file.write(contents)
        temp_file.fsync
        File.rename(temp, file)
      rescue SystemCallError
        FileUtils.rm_f(temp)
        raise
      end

      # Reads file, which must be a regular file, and raises
      # Errno::EINVAL if it isn't. So it won't follow a symlink, and won't
      # wait forever on a FIFO, whose open waits for a writer, unless it's
      # nonblocking. It checks before the open, and again on what it
      # opened, in case the file was swapped in between. The String comes
      # back in the locale's encoding, which may not be UTF-8.
      #
      # The open and the fstat after it would refuse anything the lstat
      # does, so no test can tell the lstat is there. It stays so that
      # nothing but a regular file is ever opened: opening a device node
      # can do something by itself. Pinning that would take a device node
      # in the store, and only root can make one.
      def read(file)
        raise Errno::EINVAL, "not a regular file" unless File.lstat(file).file?

        File.open(file, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |f|
          raise Errno::EINVAL, "not a regular file" unless f.stat.file?

          f.read
        end
      end

      # What's wrong with a directory that should be private to current_uid,
      # given its lstat (nil for nothing there), or nil if nothing is.
      def directory_problem(stat, current_uid)
        return "has no directory" unless stat
        return "has a path that isn't a directory" unless stat.directory?

        mode = stat.mode & 0o7777
        return format("has a directory with mode %<mode>04o, not 0700", mode:) unless mode == 0o700

        return if stat.uid == current_uid

        "has a directory owned by uid #{stat.uid}, not the current user (uid #{current_uid})"
      end

      # Whether dir, or the directory it's in, is a symlink. It looks no
      # further up. dir is normalized first, since lstat follows a symlink
      # whose name ends in a slash. absolute_path, unlike expand_path,
      # leaves a leading ~ alone.
      def linked?(dir)
        dir = File.absolute_path(dir)
        [File.dirname(dir), dir].any? { lstat(it)&.symlink? }
      end

      # The file's lstat, or nil if there's nothing there.
      def lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
