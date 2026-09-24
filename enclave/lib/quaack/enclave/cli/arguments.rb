# frozen_string_literal: true

require_relative "refused"

module Quaack
  module Enclave
    class CLI
      # Parses the arguments after the subcommand, for one step. Each is an
      # option the step declares: `--name value` for a :value option,
      # `--name` alone for a :flag, and `--run <run ID>` for a step that
      # needs a run or names one. Anything else, a repeated option, a missing value, or
      # a missing option the step requires is refused as usage. Values come back as given, and run_id is nil
      # if there's no --run; the CLI and the steps check them.
      Arguments = Data.define(:options, :run_id) do
        def self.parse(step, args)
          declared = step.run || step.run_id ? { **step.options, "run" => :value } : step.options
          args = args.dup
          options = {}
          until args.empty?
            name = option_name(args.shift)
            options[name] = option(declared, name, options, args)
          end
          required!(step, options)
          new(options: options.except("run"), run_id: options["run"])
        end

        def self.option_name(arg) = arg.start_with?("--") ? arg.delete_prefix("--") : raise(Refused, "usage")

        def self.option(declared, name, options, args)
          kind = declared[name]
          raise Refused, "usage" if kind.nil? || options.key?(name)

          kind == :flag || value(args)
        end

        def self.value(args) = args.empty? ? raise(Refused, "usage") : args.shift

        def self.required!(step, options)
          raise Refused, "usage" unless step.required.all? { options.key?(it) }
        end

        private_class_method :option_name, :option, :value, :required!
      end
    end
  end
end
