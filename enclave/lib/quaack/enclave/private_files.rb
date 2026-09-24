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

      # Writes contents to a temp file in file's directory, made 0600, and
      # renames it over file, so a reader never sees half a file. On a
      # failure it removes the temp file and re-raises.
      def write_atomically(file, contents)
        temp = File.join(File.dirname(file), ".#{File.basename(file)}.#{SecureRandom.hex(8)}.tmp")
        begin
          write_new_file(temp, contents)
          File.rename(temp, file)
        rescue SystemCallError
          FileUtils.rm_f(temp)
          raise
        end
      end

      # Makes file 0600, failing if anything is already there.
      def write_new_file(file, contents)
        File.open(file, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |f|
          f.chmod(0o600)
          f.write(contents)
          f.fsync
        end
      end

      # Reads file without following it if it's a symlink.
      def read(file) = File.open(file, File::RDONLY | File::NOFOLLOW, &:read)

      # The file's lstat, or nil if there's nothing there.
      def lstat(path)
        File.lstat(path)
      rescue Errno::ENOENT
        nil
      end
    end
  end
end
