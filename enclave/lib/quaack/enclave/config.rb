# frozen_string_literal: true

require_relative "cli/input"

module Quaack
  module Enclave
    # The quaacks config file on the jump server, ~/.quaack/config.json
    # (README, step 2): one JSON object, which the operator writes. Only the
    # keys below mean anything to this version, and any other key is left
    # alone, so a later step can add its own.
    #
    # - memory_command: the one-line shell command that prints the production
    #   server's instance memory (see Inventory::Memory). Without it, step 2
    #   records the memory as unknown.
    # - pii_columns: README 3f's configured PII list, an Array of
    #   schema.table.column globs, such as "*.users.email". Each glob has
    #   exactly three non-empty parts. A * matches any run of characters
    #   within one part, so it never crosses a dot, and every other
    #   character matches itself. Matching ignores case, so a glob can only
    #   ever match more columns than an exact match would, which withholds
    #   more: the safe way to be wrong. A table or column whose name holds
    #   a dot can be matched only by a * part. Without the key, no column
    #   is on the list.
    # - cardinality_threshold: README 3f's line between few and many
    #   distinct values, a positive Integer. Without it, it's 50.
    #
    # A missing file is an empty config. A file that's there but can't be
    # used is bad_config: a symlink, even to a good file, anything but a
    # regular file, one it can't read or that's past MAX_BYTES, JSON it
    # can't take (read as strictly as the CLI reads stdin, see CLI::Input),
    # or a value of the wrong kind. The path and the file are the
    # operator's, and the command can hold anything, so an Error names only
    # its rule and has no cause.
    class Config
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end

      # Far more than any config needs.
      MAX_BYTES = 64 * 1024
      # A memory command is one line of text, and not a blank one.
      NOT_ONE_LINE = /[\r\n\x00]/
      # README 3f: fewer than this many distinct values is few.
      DEFAULT_CARDINALITY_THRESHOLD = 50

      def self.default_path = File.join(Dir.home, ".quaack", "config.json")

      def self.load(path = default_path)
        text = read(path)
        text ? new(parse(text)) : new({})
      end

      # The file's text, or nil if nothing's at path. NOFOLLOW refuses a
      # symlink. A directory fails to read, and NONBLOCK keeps a FIFO from
      # waiting for a writer, so it reads as empty, which isn't JSON.
      def self.read(path)
        File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
          text = file.read(MAX_BYTES + 1) || +""
          raise Error, "bad_config" if text.bytesize > MAX_BYTES

          text.force_encoding(Encoding::UTF_8)
        end
      rescue Errno::ENOENT
        nil
      rescue SystemCallError, IOError
        raise Error, "bad_config", cause: nil
      end

      def self.parse(text)
        object = CLI::Input.parse_document(text)
        raise Error, "bad_config" unless object.instance_of?(Hash)

        object
      rescue CLI::Refused
        raise Error, "bad_config", cause: nil
      end

      private_class_method :read, :parse

      attr_reader :memory_command, :pii_columns, :cardinality_threshold

      def initialize(object)
        @memory_command = object["memory_command"]
        raise Error, "bad_config" unless @memory_command.nil? || one_line?(@memory_command)

        @pii_columns = object.fetch("pii_columns", []).freeze
        @pii_globs = globs(@pii_columns)
        @cardinality_threshold = object.fetch("cardinality_threshold", DEFAULT_CARDINALITY_THRESHOLD)
        raise Error, "bad_config" unless @cardinality_threshold.instance_of?(Integer) && @cardinality_threshold.positive?
      end

      # Whether a glob in pii_columns matches the column. table is a TableName.
      def pii_column?(table, column)
        parts = [table.schema, table.name, column]
        @pii_globs.any? { |glob| glob.zip(parts).all? { |pattern, part| pattern.match?(part) } }
      end

      private

      def globs(list)
        raise Error, "bad_config" unless list.instance_of?(Array)

        list.map do |glob|
          parts = glob.split(".", -1) if glob.instance_of?(String) && !NOT_ONE_LINE.match?(glob)
          raise Error, "bad_config" unless parts&.size == 3 && parts.none?(&:empty?)

          parts.map { |part| /\A#{part.split("*", -1).map { Regexp.escape(it) }.join(".*")}\z/mi }
        end
      end

      def one_line?(command) = command.instance_of?(String) && !NOT_ONE_LINE.match?(command) && command.match?(/\S/)
    end
  end
end
