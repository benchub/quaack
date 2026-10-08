# frozen_string_literal: true

require_relative "../burndown"

module Quaack
  module Driver
    class Provenance
      # The run's LLM calls in the record (llm_calls, by step and by
      # provider), so a resumed run counts the calls its earlier processes
      # made as well as its own.
      module Calls
        # The LLM calls earlier processes of the run recorded, as a Burndown.
        def earlier
          calls = @record.fetch("llm_calls", {})
          @earlier ||= Burndown.restore(calls.fetch("steps", {}), calls.fetch("providers", {}))
        end

        # Records what the router (client) did: the providers it marked
        # down, clearing earlier downs of those it asked and didn't (up!),
        # and the run's LLM calls, earlier's and this process's so far.
        def router!(client)
          down!(client.down).up!(client.burndown.llm_calls_by_provider.keys - client.down.keys)
          @record["llm_calls"] = counts(Burndown.sum([earlier, client.burndown]))
          self
        end

        private

        def counts(sum)
          { "steps" => sum.llm_calls.to_h, "providers" => sum.llm_calls_by_provider.transform_values(&:to_h) }
        end
      end
    end
  end
end
