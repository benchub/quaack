# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # operator-rewrites runs only on rewrites of your own, so the enclave
      # has no record of it for a run given none (task 20261016-12). The
      # driver knows it gave none, so fill gives the payload the record the
      # enclave would have made: taking in what the nearest earlier arrival
      # stage, llm-rewrites or rewrite-rules, sent on, adding nothing, and
      # sending it all on. The report then shows "From you: 0" instead of
      # "not recorded".
      module OwnRewrites
        STAGE = "operator-rewrites"
        EARLIER = %w[llm-rewrites rewrite-rules].freeze

        module_function

        # The payload, with that record when own_rewrites, how many rewrites
        # of your own the run was given, is 0, the stage has no record, and
        # an earlier arrival stage counted what it sent on. Otherwise, the
        # payload as it is.
        def fill(payload, own_rewrites)
          stages = payload.dig("burndown", "stages")
          return payload unless own_rewrites&.zero? && stages && !stages.key?(STAGE)

          carried = EARLIER.lazy.filter_map { stages.dig(it, "rewrites", "out") }.first
          return payload unless carried

          record = { "in" => carried, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => carried,
                     "extra" => {} }
          burndown = payload["burndown"].merge("stages" => stages.merge(STAGE => { "rewrites" => record }))
          payload.merge("burndown" => burndown)
        end
      end
    end
  end
end
