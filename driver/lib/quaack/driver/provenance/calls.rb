# frozen_string_literal: true

require_relative "../burndown"

module Quaack
  module Driver
    class Provenance
      # The run's LLM calls in the record (llm_calls, by step and by
      # provider), and each provider's wait and tokens (llm_usage, as
      # Burndown#llm_usage gives them), so a resumed run counts what its
      # earlier processes did as well as its own.
      module Calls
        # The LLM calls earlier processes of the run recorded, as a Burndown.
        def earlier
          calls = @record.fetch("llm_calls", {})
          @earlier ||= Burndown.restore(calls.fetch("steps", {}), calls.fetch("providers", {}),
                                        @record.fetch("llm_usage", {}))
        end

        # Records what the router (client) did: the providers it marked
        # down, clearing earlier downs of those it asked and didn't (up!),
        # and the run's LLM calls, earlier's and this process's so far.
        def router!(client)
          down!(client.down).up!(client.burndown.llm_calls_by_provider.keys - client.down.keys)
          @record.merge!(totals(Burndown.sum([earlier, client.burndown])))
          self
        end

        private

        def totals(sum)
          { "llm_calls" => { "steps" => sum.llm_calls.to_h,
                             "providers" => sum.llm_calls_by_provider.transform_values(&:to_h) },
            "llm_usage" => sum.llm_usage.transform_values(&:to_h) }
        end
      end
    end
  end
end
