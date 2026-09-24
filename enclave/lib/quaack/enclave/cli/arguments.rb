# frozen_string_literal: true

require_relative "refused"

module Quaack
  module Enclave
    class CLI
      # Parses the arguments after the subcommand, for one step. Each is an
      # option the step declares: `--name value` for a :value option,
      # `--name` alone for a :flag, and `--run <run ID>` for a step that
      # needs a run. Anything else, a repeated option, or a missing value
      # is refused as usage. Values come back as given; steps check them.
      Arguments = Data.define(:options, :run_id) do
        def self.parse(step, args)
          args = args.dup
          options = {}
          run_id = nil
          until args.empty?
            name = option_name(args.shift)
            if name == "run" && step.run && run_id.nil?
              run_id = value(args)
            else
              options[name] = option(step, name, options, args)
            end
          end
          raise Refused, "usage" if step.run && run_id.nil?

          new(options:, run_id:)
        end

        def self.option_name(arg) = arg.start_with?("--") ? arg.delete_prefix("--") : raise(Refused, "usage")

        def self.option(step, name, options, args)
          kind = step.options[name]
          raise Refused, "usage" if kind.nil? || options.key?(name)

          kind == :flag || value(args)
        end

        def self.value(args) = args.empty? ? raise(Refused, "usage") : args.shift

        private_class_method :option_name, :option, :value
      end
    end
  end
end
