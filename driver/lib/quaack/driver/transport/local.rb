# frozen_string_literal: true

require "open3"
require_relative "reply"

module Quaack
  module Driver
    module Transport
      class Local
        def initialize(command:)
          @command = command
        end

        def call(subcommand, args: {}, input: nil)
          flags = args.flat_map { |name, value| ["--#{name}", value] }
          out, status = Open3.capture2(*@command, subcommand, *flags)
          Result.new(messages: Reply.parse(out, status, subcommand:))
        end
      end
    end
  end
end
