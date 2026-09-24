# frozen_string_literal: true

module Quaack
  module Enclave
    module Redaction
      # A placeholder's row counts, from the plan node that consumes it (see
      # "Row counts" in Redaction). Every value is a name or a number from
      # the plan, never a literal.
      module Rows
        module_function

        # consumers are every Plan::Consumer of one placeholder.
        def of(consumers)
          nodes = consumers.uniq { |consumer| consumer.fields.object_id }
          return { "status" => "none" } if nodes.empty?
          return { "status" => "ambiguous" } if nodes.size > 1

          found(nodes.first)
        end

        def found(consumer)
          fields = consumer.fields
          { "status" => "found", "node" => (fields["Node Type"] if fields["Node Type"].is_a?(String)),
            "qual" => consumer.qual, "estimated_rows" => number(fields["Plan Rows"]),
            "actual_rows" => number(fields["Actual Rows"]), "actual_loops" => number(fields["Actual Loops"]) }
        end

        def number(value) = (value if value.is_a?(Numeric))
      end

      private_constant :Rows
    end
  end
end
