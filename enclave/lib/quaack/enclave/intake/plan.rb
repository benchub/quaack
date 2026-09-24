# frozen_string_literal: true

require_relative "error"
require_relative "../cli/input"

module Quaack
  module Enclave
    module Intake
      # Checks the operator's EXPLAIN (ANALYZE, BUFFERS, SETTINGS, FORMAT
      # JSON) output, in this order, and returns it parsed:
      #
      # 1. plan_not_json: it isn't one JSON document, read as strictly as
      #    the CLI reads stdin (see CLI::Input): UTF-8, no repeated key, no
      #    comment, no unknown escape, and no number too big for a Float.
      # 2. plan_bad_shape: it isn't what EXPLAIN writes for one statement,
      #    an Array of one object whose "Plan" is an object, with a
      #    "Settings" that's an object of Strings if it's there at all.
      #    Postgres 18 writes an empty Settings when every setting is the
      #    default, but the key isn't required.
      # 3. plan_not_analyzed: the root plan node has neither "Actual Rows"
      #    nor "Actual Total Time", which only ANALYZE writes. TIMING OFF
      #    leaves out the times but keeps the rows.
      # 4. plan_no_buffers: the root plan node has none of the block
      #    counters BUFFERS writes. Without ANALYZE, BUFFERS writes them only
      #    under "Planning", but that's already refused above.
      module Plan
        BUFFER_COUNTERS = %w[Shared Local Temp].product(%w[Hit Read Dirtied Written])
                                               .map { |kind, what| "#{kind} #{what} Blocks" }.freeze
        ANALYZE_KEYS = ["Actual Rows", "Actual Total Time"].freeze

        module_function

        def check(bytes)
          plan = parse(bytes.dup.force_encoding(Encoding::UTF_8))
          raise Error, "plan_bad_shape" unless shaped?(plan)

          root = plan[0]["Plan"]
          raise Error, "plan_not_analyzed" unless ANALYZE_KEYS.any? { root.key?(it) }
          raise Error, "plan_no_buffers" unless BUFFER_COUNTERS.any? { root.key?(it) }

          plan
        end

        def parse(text)
          CLI::Input.parse_document(text)
        rescue CLI::Refused
          raise Error, "plan_not_json", cause: nil
        end

        def shaped?(plan)
          return false unless plan.instance_of?(Array) && plan.size == 1 && plan[0].instance_of?(Hash)

          settings = plan[0].fetch("Settings", {})
          plan[0]["Plan"].instance_of?(Hash) && settings.instance_of?(Hash) &&
            settings.each_value.all? { it.instance_of?(String) } # rubocop:disable Style/PredicateWithKind
        end
      end
    end
  end
end
