# frozen_string_literal: true

require "json"

module Quaack
  module Driver
    # The driver config on the laptop, ~/.quaack/driver.json: a JSON object.
    # `quaack start` reads its jump_command, and `quaack run` its llm block
    # (see LLM.settings). Both, and `quaack setup`, read
    # enclave_timeout_seconds, if it's there:
    # how long each enclave call may run, in seconds, before the driver
    # kills it (Transport::Base::DEFAULT_TIMEOUT without it).
    module DriverConfig
      # A config file that isn't a JSON object, or can't be read. The
      # message never quotes it.
      class Bad < StandardError
        def initialize(path, problem) = super("bad_driver_config: #{path}: #{problem}")
      end

      # What --enclave-timeout-seconds takes: digits, with an optional
      # fractional part. Not Float()'s other forms, such as 0x10, 1_000,
      # or 1e3.
      PLAIN = /\A\d+(\.\d+)?\z/

      # A --enclave-timeout-seconds that isn't a positive number.
      class BadFlag < StandardError
        def initialize = super("--enclave-timeout-seconds must be a positive number")
      end

      def self.path(home) = File.expand_path(File.join(home, ".quaack", "driver.json"))

      # The config under home as a Hash, or nil when nothing is there. A
      # driver.json it can't reach, such as one in a directory it can't
      # read, or one that isn't a file, is Bad, not missing.
      def self.read(home)
        path = path(home)
        return unless there?(path)

        config = parse(path)
        raise Bad.new(path, "not a JSON object") unless config.is_a?(Hash)

        validate_jump_command(config, path)
        validate_enclave_timeout(config, path)
        config
      end

      # Whether value is a positive, finite number of seconds.
      def self.seconds?(value) = value.is_a?(Numeric) && value.positive? && value.finite?

      # How long each enclave call may run, in seconds: flag, the text of
      # --enclave-timeout-seconds, if given, else config's (as read gives
      # it, or nil) enclave_timeout_seconds, else default. A flag that isn't
      # a plain decimal number of seconds, PLAIN, or isn't positive raises
      # BadFlag.
      def self.enclave_timeout(config, flag, default)
        return config&.fetch("enclave_timeout_seconds", nil) || default unless flag

        (Float(flag) if PLAIN.match?(flag)).then { it if seconds?(it) } or raise BadFlag
      end

      # Whether something is at path. Unlike File.exist?, it raises Bad
      # when it can't tell, when what's there isn't a file (a FIFO would
      # block the read), or when it's a symlink whose target is missing.
      def self.there?(path)
        File.stat(path).file? or raise Bad.new(path, "can't read it")
      rescue Errno::ENOENT, Errno::ENOTDIR
        raise Bad.new(path, "it's a symlink to a missing file") if dangling_symlink?(path)

        false
      rescue Errno::EACCES
        raise Bad.new(path, "can't read it (permission denied)")
      rescue SystemCallError
        raise Bad.new(path, "can't read it")
      end
      private_class_method :there?

      def self.dangling_symlink?(path)
        File.lstat(path).symlink?
      rescue SystemCallError
        false
      end
      private_class_method :dangling_symlink?

      # The file's JSON, or Bad if it isn't JSON.
      def self.parse(path)
        text = File.read(path)
        JSON.parse(text)
      rescue JSON::ParserError => e
        line, column = json_error_location(e)
        raise Bad.new(path, "not valid JSON (line #{line}, column #{column})")
      rescue Errno::EACCES
        raise Bad.new(path, "can't read it (permission denied)")
      rescue SystemCallError
        raise Bad.new(path, "can't read it")
      end
      private_class_method :parse

      def self.validate_jump_command(config, path)
        raise Bad.new(path, "no jump_command") unless config.key?("jump_command")

        command = config["jump_command"]
        return if command.is_a?(String) && command.match?(/\A[^\n\r]*\S[^\n\r]*\z/)

        raise Bad.new(path, "jump_command isn't one non-blank line")
      end
      private_class_method :validate_jump_command

      def self.validate_enclave_timeout(config, path)
        return if !config.key?("enclave_timeout_seconds") || seconds?(config["enclave_timeout_seconds"])

        raise Bad.new(path, "enclave_timeout_seconds must be a positive number")
      end
      private_class_method :validate_enclave_timeout

      def self.json_error_location(error)
        match = error.message.match(/ at line (?<line>\d+) column (?<column>\d+)\z/)
        return [match[:line].to_i, match[:column].to_i] if match

        [1, 1]
      end
      private_class_method :json_error_location
    end
  end
end
