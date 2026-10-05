# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require_relative "plain_data"
require_relative "private_files"
require_relative "store_format"

module Quaack
  module Enclave
    # The governed store (DESIGN.md, "Where QUAACK runs"): one directory per
    # run on the jump server, holding input's inputs and every
    # intermediate result between calls to the enclave script. Everything
    # in it can be value-class data, so it never leaves the enclave.
    #
    #   store = Store.create                      # a new run under ~/.quaack/runs
    #   store.write("literals", ["a", 1])         # <run dir>/literals.json
    #   Store.open(store.run_id).read("literals") # => ["a", 1]
    #   store.teardown                            # deletes the run's directory
    #   Store.teardown(run_id)                    # the same, by run ID (store/teardown.rb)
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
      # Each kind's rule is for ErrorFilter's error line.
      class Error < StandardError
        def rule = "store_error"
      end

      # What open raises for a run path that isn't a run directory it would
      # open, so what teardown raises for one it won't delete.
      class BadRun < Error
        def rule = "bad_run"
      end

      # What create, open, and teardown raise for a base they can't use:
      # one they can't make or look in, such as a file or one under a
      # directory they can't search, or one that's linked (LINKED_BASE).
      class BadBase < Error
        def rule = "bad_store_base"
      end

      # What read raises for an entry that isn't there, such as a step's
      # upstream entry when the step that writes it hasn't run. Its rule,
      # missing_ and the entry's name, is what the step's error line names
      # (see ErrorFilter), for every step at once. Entry names are fixed
      # lowercase words in the code, never data.
      class MissingEntry < Error
        attr_reader :rule

        def initialize(message, entry:)
          super(message)
          @rule = "missing_#{entry}"
        end
      end

      # QUAACK makes the base and the directory above it, ~/.quaack/runs
      # and ~/.quaack, so if either is a symlink, the store would live
      # wherever it points. So create, open, and teardown raise BadBase for
      # either, and make, read, and delete nothing through it. The
      # directories above those, such as the operator's home, are the
      # operator's to arrange.
      LINKED_BASE = "the store's base is a symlink, or is in one, so it wasn't used"

      # A run ID: the UTC time the run started, then eight random hex
      # characters, such as 20260923T221500Z-0a1b2c3d.
      RUN_ID = /\A\d{8}T\d{6}Z-[0-9a-f]{8}\z/

      ENTRY_NAME = /\A[a-z][a-z0-9_]*\z/

      def self.default_base = File.join(Dir.home, ".quaack", "runs")

      # Starts a new run: makes its directory under base, making base (and
      # any missing directory above it) mode 0700 first.
      def self.create(base: default_base)
        in_base(base, "couldn't make the store's base directory") { PrivateFiles.make_directories(base) }
        run_id = "#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}"
        path = File.join(base, run_id)
        in_base(base, "couldn't make a run directory in the store's base") { PrivateFiles.make_directory(path) }
        new(run_id, path).tap { StoreFormat.mark(it) }
      end

      # Opens a run an earlier call started. The run directory must be a
      # real directory, not a symlink, mode 0700, and owned by the current
      # user, or it raises BadRun. current_uid is there for tests.
      def self.open(run_id, base: default_base, current_uid: Process.euid)
        path = run_path(run_id, base)
        check_run_directory(run_id, path, base, current_uid)
        new(run_id, path)
      end

      # What open checks, so teardown can check it again just before the
      # delete.
      def self.check_run_directory(run_id, path, base, current_uid)
        problem = PrivateFiles.directory_problem(look_up(run_id, base) { PrivateFiles.lstat(path) }, current_uid)
        raise BadRun, "run #{run_id} #{problem}" if problem
      end

      # Private helpers for the class and its instances alike, so teardown
      # checks the base just as open does.
      module BaseChecks
        private

        # Refuses a linked base (see LINKED_BASE), and yields, turning a
        # SystemCallError from either into BadBase with failure as its
        # message. The SystemCallError names a file, which can be below
        # base, so it's left behind.
        def in_base(base, failure)
          raise BadBase, LINKED_BASE, cause: nil if PrivateFiles.linked?(base)

          yield
        rescue SystemCallError
          raise BadBase, failure, cause: nil
        end

        # in_base, for a lookup of the run's path.
        def look_up(run_id, base, &) = in_base(base, "couldn't look up run #{run_id} in the store's base", &)
      end
      extend BaseChecks
      include BaseChecks

      private_constant :BaseChecks

      # The run ID usually comes from argv, so it must be exactly in the
      # RUN_ID form before it goes into a path.
      def self.run_path(run_id, base)
        return File.join(base, run_id) if run_id.is_a?(String) && RUN_ID.match?(run_id)

        raise Error, "run ID isn't in the form YYYYMMDDTHHMMSSZ-xxxxxxxx"
      end

      private_class_method :run_path, :check_run_directory, :new

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

      # Whether something is at the entry's file, so a caller can tell an
      # entry that was never written from one that can't be read. Anything
      # there counts, even a symlink, so read then fails rather than the
      # caller starting afresh.
      def entry?(name) = !PrivateFiles.lstat(entry_path(entry_name(name))).nil?

      # The names of the entries the run holds, in no order.
      def entry_names
        Dir.children(path).filter_map { it.delete_suffix(".json") if it.end_with?(".json") }
      rescue SystemCallError
        raise Error, "couldn't list the entries of run #{run_id}", cause: nil
      end

      # Returns the entry's data. It won't follow an entry that's a symlink.
      def read(name)
        name = entry_name(name)
        text = begin
          PrivateFiles.read(entry_path(name))
        rescue Errno::ENOENT
          raise MissingEntry.new("no entry #{name} in run #{run_id}", entry: name), cause: nil
        rescue SystemCallError
          raise Error, "couldn't read entry #{name} in run #{run_id}", cause: nil
        end
        parse(name, text)
      end

      # Deletes the run's directory and everything in it. It does nothing
      # if the directory is already gone. It won't delete a run path that's
      # been replaced by something other than a directory, and it removes a
      # symlink inside the run directory without following it. It raises
      # BadBase for a base open would refuse.
      def teardown
        stat = look_up(run_id, File.dirname(path)) { PrivateFiles.lstat(path) }
        return unless stat
        raise BadRun, "run #{run_id}: its path isn't a directory, so it wasn't deleted" unless stat.directory?

        begin
          FileUtils.rm_r(path)
        rescue SystemCallError
          # The error names the file, and a file name can be a value.
          raise Error, "couldn't delete the directory of run #{run_id}", cause: nil
        end
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
          # json doesn't count an empty innermost container toward
          # max_nesting, so PlainData checks the depth again.
          PlainData.check(JSON.parse(text, max_nesting: PlainData::MAX_DEPTH))
        rescue SystemStackError, PlainData::NotPlain
          raise Error, "entry #{name} in run #{run_id} is nested too deep to read", cause: nil
        end
      rescue JSON::ParserError
        raise Error, "entry #{name} in run #{run_id} isn't valid JSON", cause: nil
      end
    end
  end
end
