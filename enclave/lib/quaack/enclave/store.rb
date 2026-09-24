# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require_relative "plain_data"
require_relative "private_files"

module Quaack
  module Enclave
    # The governed store (README, "Where QUAACK runs"): one directory per
    # run on the jump server, holding the step 1 inputs and every
    # intermediate result between calls to the enclave script. Everything
    # in it can be value-class data, so it never leaves the enclave.
    #
    #   store = Store.create                      # a new run under ~/.quaack/runs
    #   store.write("literals", ["a", 1])         # <run dir>/literals.json
    #   Store.open(store.run_id).read("literals") # => ["a", 1]
    #   store.teardown                            # deletes the run's directory
    #
    # Each result is a JSON file named for its entry. Entry names are
    # lowercase words, such as inputs or placeholder_map. Reads return what
    # JSON gives back, so Symbols come back as Strings.
    #
    # The run directory is mode 0700 and each file 0600, whatever the umask
    # is (see PrivateFiles). Encryption at rest comes from the jump server's
    # disk encryption, not from here.
    #
    # Errors are Store::Error. They name only the run ID and the entry
    # name, which are shape, and never carry a file's contents or a stored
    # value, so they have no cause.
    class Store
      class Error < StandardError; end

      # A run ID: the UTC time the run started, then eight random hex
      # characters, such as 20260923T221500Z-0a1b2c3d.
      RUN_ID = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/

      ENTRY_NAME = /\A[a-z][a-z0-9_]*\z/

      def self.default_base = File.join(Dir.home, ".quaack", "runs")

      # Starts a new run: makes its directory under base, making base (and
      # any missing directory above it) mode 0700 first.
      def self.create(base: default_base)
        PrivateFiles.make_directories(base)
        run_id = "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
        path = File.join(base, run_id)
        PrivateFiles.make_directory(path)
        new(run_id, path)
      end

      # Opens a run an earlier call started. The run ID usually comes from
      # argv, so it must be exactly in the RUN_ID form before it goes into a
      # path. The run directory must be a real directory, not a symlink,
      # mode 0700, and owned by the current user. current_uid is there for
      # tests.
      def self.open(run_id, base: default_base, current_uid: Process.euid)
        unless run_id.is_a?(String) && RUN_ID.match?(run_id)
          raise Error, "run ID isn't in the form YYYYMMDDTHHMMSSZ-xxxxxxxx"
        end

        path = File.join(base, run_id)
        problem = directory_problem(PrivateFiles.lstat(path), current_uid)
        raise Error, "run #{run_id} #{problem}" if problem

        new(run_id, path)
      end

      # What's wrong with a run directory, given its lstat, or nil if
      # nothing is.
      def self.directory_problem(stat, current_uid)
        return "has no directory" unless stat
        return "has a path that isn't a directory" unless stat.directory?

        mode = stat.mode & 0o7777
        return format("has a directory with mode %<mode>04o, not 0700", mode:) unless mode == 0o700

        return if stat.uid == current_uid

        "has a directory owned by uid #{stat.uid}, not the current user (uid #{current_uid})"
      end

      private_class_method :directory_problem, :new

      attr_reader :run_id, :path

      def initialize(run_id, path)
        @run_id = run_id
        @path = path
      end

      # Stores data as the entry's JSON file, replacing any earlier one.
      # The write is atomic: a reader sees the old file or the new one.
      def write(name, data)
        name = entry_name(name)
        json = generate(name, data)
        begin
          PrivateFiles.write_atomically(entry_path(name), json)
        rescue SystemCallError
          raise Error, "couldn't write entry #{name} in run #{run_id}", cause: nil
        end
        nil
      end

      # Returns the entry's data. It won't follow an entry that's a symlink.
      def read(name)
        name = entry_name(name)
        text = begin
          PrivateFiles.read(entry_path(name))
        rescue Errno::ENOENT
          raise Error, "no entry #{name} in run #{run_id}", cause: nil
        rescue SystemCallError
          raise Error, "couldn't read entry #{name} in run #{run_id}", cause: nil
        end
        parse(name, text)
      end

      # Deletes the run's directory and everything in it. It does nothing
      # if the directory is already gone. It won't delete a run path that's
      # been replaced by something other than a directory, and it removes a
      # symlink inside the run directory without following it.
      def teardown
        stat = PrivateFiles.lstat(path)
        return unless stat
        raise Error, "run #{run_id}: its path isn't a directory, so it wasn't deleted" unless stat.directory?

        FileUtils.rm_r(path)
        nil
      end

      private

      def entry_name(name)
        name = name.name if name.is_a?(Symbol)
        return name if name.is_a?(String) && ENTRY_NAME.match?(name)

        raise Error, "entry name must be a lowercase word, such as placeholder_map"
      end

      def entry_path(name) = File.join(path, "#{name}.json")

      # Data must be plain JSON data (see PlainData), or the json that ships
      # with Ruby would store other objects as their to_s. The error JSON
      # raises can quote the data, so it's left behind. The check already
      # caps the depth, so JSON needn't. In a thread with a small stack, JSON
      # can still run out of stack (see PlainData::MAX_DEPTH).
      def generate(name, data)
        PlainData.check(data)
        JSON.generate(data, max_nesting: false)
      rescue PlainData::NotPlain, JSON::GeneratorError, SystemStackError
        raise Error, "entry #{name} in run #{run_id} couldn't be written as JSON", cause: nil
      end

      # The file is read as UTF-8 whatever the locale is, and no deeper
      # than PlainData::MAX_DEPTH, the most write stores. JSON accepts bytes
      # that aren't UTF-8 inside a string, so check for them first. The
      # parse error can quote the file, so it's left behind.
      def parse(name, text)
        text = text.force_encoding(Encoding::UTF_8)
        raise JSON::ParserError unless text.valid_encoding?

        begin
          JSON.parse(text, max_nesting: PlainData::MAX_DEPTH)
        rescue SystemStackError
          raise Error, "entry #{name} in run #{run_id} is nested too deep to read", cause: nil
        end
      rescue JSON::ParserError
        raise Error, "entry #{name} in run #{run_id} isn't valid JSON", cause: nil
      end
    end
  end
end
