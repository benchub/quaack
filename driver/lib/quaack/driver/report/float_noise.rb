# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # A rewrite whose production comparison failed only on float noise
      # (its fate's float_noise, task 20261111-192302-1) is likely right, so
      # the report counts it apart (the user, 2026-11-11, task
      # 20261111-223753-1): not as a wrong result, nor as a bug in the rule
      # that made it, nor as stopped for another reason, but as failed on
      # float noise. Accountability counts it in a column of its own, and
      # Survival still claims enumerate's bound for it.
      #
      # The enclave doesn't split these out of the two lists it builds from
      # the same verdicts, so apart does, from the payload's rewrites:
      #
      # - rule_bugs loses a result-comparison entry whose rewrite is
      #   flagged. RuleBugs names result-comparison only when the rewrite
      #   got through every earlier test and a failing verdict was a
      #   mismatch, which is when its fate is production_mismatch.
      # - The burndown's measurement stage, which drops a rewrite by its
      #   fate, drops the flagged ones as float_noise instead, taken from
      #   their fate's count, never more than it holds.
      #
      #   FloatNoise.apart(payload)  # => payload, with those two changed
      module FloatNoise
        FATES = %w[production_mismatch production_not_compared].freeze

        # The burndown drop a flagged rewrite counts as (Words::COUNTS).
        DROP = "float_noise"

        STEP = "result-comparison"

        module_function

        def flagged?(entry) = entry.is_a?(Hash) && entry["float_noise"] == true && FATES.include?(entry["fate"])

        def apart(payload)
          rewrites = payload["rewrites"]
          flagged = rewrites.is_a?(Array) ? rewrites.select { flagged?(it) } : []
          return payload if flagged.empty?

          bugs = payload["rule_bugs"]
          names = flagged.map { it["rewrite"] }
          payload.merge(
            **(bugs.is_a?(Array) ? { "rule_bugs" => bugs.reject { noise_bug?(it, names) } } : {}),
            **(burndown?(payload) ? { "burndown" => burndown(payload["burndown"], flagged) } : {})
          )
        end

        def noise_bug?(bug, names)
          bug.is_a?(Hash) && bug["step"] == STEP && names.include?(bug["rewrite"])
        end

        def burndown?(payload) = payload["burndown"].is_a?(Hash) && measured(payload["burndown"]).is_a?(Hash)

        def measured(burndown) = burndown.dig("stages", "measurement", "rewrites", "dropped")

        def burndown(burndown, flagged)
          record = burndown.dig("stages", "measurement", "rewrites")
          stages = burndown["stages"].merge("measurement" => burndown["stages"]["measurement"].merge(
            "rewrites" => record.merge("dropped" => dropped(record["dropped"], flagged))
          ))
          burndown.merge("stages" => stages)
        end

        # dropped, with each flagged rewrite moved from its fate's count to
        # DROP, which goes just after the first of FATES.
        def dropped(counts, flagged)
          moved = moves(counts, flagged)
          total = moved.values.sum
          return counts if total.zero?

          counts.each_with_object({}) do |(name, count), out|
            out[name] = moved.fetch(name, 0).zero? ? count : count - moved[name]
            out[DROP] = total if FATES.include?(name) && !out.key?(DROP)
          end
        end

        # How many of each fate's count to move: its flagged rewrites, never
        # more than the count holds.
        def moves(counts, flagged)
          FATES.to_h do |fate|
            held = counts[fate]
            [fate, held.is_a?(Integer) ? flagged.count { it["fate"] == fate }.clamp(0, held) : 0]
          end
        end
      end
    end
  end
end
