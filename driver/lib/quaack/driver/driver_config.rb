# frozen_string_literal: true

require "json"

module Quaack
  module Driver
    # The driver config on the laptop, ~/.quaack/driver.json: a JSON object.
    # `quaack start` reads its jump_command, and `quaack run` its llm block
    # (see LLM.settings).
    module DriverConfig
      # A config file that isn't a JSON object, or can't be read. The
      # message never quotes it.
      class Bad < StandardError
        def initialize(message = "~/.quaack/driver.json must be a JSON object") = super
      end

      def self.path(home) = File.join(home, ".quaack", "driver.json")

      # The config under home as a Hash, or nil when nothing is there. A
      # driver.json it can't reach, such as one in a directory it can't
      # read, or one that isn't a file, is Bad, not missing.
      def self.read(home)
        path = path(home)
        return unless there?(path)

        config = parse(path)
        raise Bad unless config.is_a?(Hash)

        config
      end

      # Whether something is at path. Unlike File.exist?, it raises Bad
      # when it can't tell, or when what's there isn't a file.
      def self.there?(path)
        File.stat(path).file? or raise Bad, "can't read ~/.quaack/driver.json"
      rescue Errno::ENOENT, Errno::ENOTDIR
        false
      rescue SystemCallError
        raise Bad, "can't read ~/.quaack/driver.json"
      end
      private_class_method :there?

      # The file's JSON, or nil if it isn't JSON.
      def self.parse(path)
        JSON.parse(File.read(path))
      rescue JSON::ParserError
        nil
      rescue SystemCallError
        raise Bad, "can't read ~/.quaack/driver.json"
      end
      private_class_method :parse
    end
  end
end
