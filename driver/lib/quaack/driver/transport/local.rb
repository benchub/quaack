# frozen_string_literal: true

require_relative "base"

module Quaack
  module Driver
    module Transport
      # Runs the enclave script on this machine, in a child process, for
      # tests: command is how to start it, such as
      # `[RbConfig.ruby, "-I", "enclave/lib", "enclave/exe/quaacks"]`, and
      # the call's argv follows it. It pipes the same stdin JSON the ssh
      # transport does. It never loads the enclave gem into the driver's
      # process, so the boundary holds here too.
      class Local < Base
        def initialize(command:, **)
          super(**)
          @command = command.dup.freeze
        end

        private

        def command(argv) = [*@command, *argv]
      end
    end
  end
end
