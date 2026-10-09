# frozen_string_literal: true

module Quaack
  module Driver
    class Provenance
      # The checks a record read back passes through: each part is kept
      # only if it has exactly the shape a writer gives it.
      module Shape
        # A unit's keys, and the most rounds a rewrite gets (Counterexamples::ROUNDS).
        UNIT_KEYS = %w[entry rounds after pairing].freeze
        MOST_ROUNDS = 3
        # A unit's pairing outcomes (LLM::Router::Pairing#outcome).
        PAIRINGS = %w[met not_met not_applicable unchecked].freeze
        # The steps that fan out (LLM::RoutingChecks::FAN_OUT_STEPS), and the
        # rules a branch is dropped for (LLM::Router::FAILS_OVER).
        FAN_OUT_STEPS = %w[llm-rewrites llm-index-ideas rewrite-llm-index-ideas].freeze
        FAILS_OVER = %w[llm_rate_limited llm_unavailable llm_auth llm_bad_response].freeze
        BRANCH_KEYS = %w[entry rule step].freeze
        # A provider's usage counts besides seconds (Burndown#llm_usage).
        USAGE = %w[used reported input output cached reasoning].freeze

        module_function

        def record(raw)
          kept = { "providers" => list(raw["providers"]) { provider(it) }, **rewrites(raw), **parts(raw) }
                 .reject { |_, v| v.nil? || v.empty? }
          name?(raw["operator_inference"]) ? kept.merge("operator_inference" => raw["operator_inference"]) : kept
        end

        # The counterexample rounds, index rounds, and failed branches.
        def parts(raw)
          { "counterexamples" => counterexamples(raw["counterexamples"]),
            "index_ideas" => index_ideas(raw["index_ideas"]),
            "failed_branches" => list(raw["failed_branches"]) { branch(it) },
            "llm_calls" => llm_calls(raw["llm_calls"]), "llm_usage" => llm_usage(raw["llm_usage"]) }
        end

        # Each provider's wait and tokens (Burndown#llm_usage), by name:
        # seconds of zero or more, and counts of the rest. Any other key
        # is dropped, and a provider without seconds, used, and reported.
        def llm_usage(raw)
          map(raw) { |name, counts| name?(name) && counts.is_a?(Hash) }
            &.transform_values { it.select { |kind, n| usage?(kind, n) } }
            &.select { |_, kept| %w[seconds used reported].all? { kept.key?(it) } }
        end

        def usage?(kind, value)
          return value.is_a?(Numeric) && !value.negative? if kind == "seconds"

          USAGE.include?(kind) && count?(value)
        end

        # The run's LLM calls so far: steps, by LLM step, and providers, by
        # name and then LLM step. Any other count is dropped.
        def llm_calls(raw)
          return unless raw.is_a?(Hash)

          providers = map(raw["providers"]) { |name, _| name?(name) } || {}
          { "steps" => steps(raw["steps"]), "providers" => providers.transform_values { steps(it) } }
        end

        # Counts by LLM step, each of zero or more.
        def steps(raw) = map(raw) { |step, n| Protocol::Burndown::LLM_STEPS.include?(step) && count?(n) } || {}

        def rewrites(raw)
          { "rewrites" => map(raw["rewrites"]) { |k, v| REWRITE.match?(k) && name?(v) },
            "rewrites_proposed" => map(raw["rewrites_proposed"]) { |k, v| name?(k) && count?(v) } }
        end

        def provider(raw)
          return unless raw.is_a?(Hash) && name?(raw["name"]) && PROVIDER.match?(raw["provider"].to_s) &&
                        raw["model"].is_a?(String) && MODEL.match?(raw["model"])

          down = raw["down"]
          raw.slice("name", "provider", "model").merge(rule?(down) ? { "down" => down } : {})
        end

        # A failed fan-out branch: its step, one that fans out, its entry,
        # and its rule, one that drops a branch. No other key.
        def branch(raw)
          return unless raw.is_a?(Hash) && raw.keys.sort == BRANCH_KEYS && name?(raw["entry"])

          raw.slice("step", "entry", "rule") if FAN_OUT_STEPS.include?(raw["step"]) && FAILS_OVER.include?(raw["rule"])
        end

        # A counterexample unit: its entry, its rounds, one to three, since
        # no rewrite gets more, for a fresh start, after, a rule, and
        # pairing, one of PAIRINGS. No other key.
        def unit(raw)
          return unless raw.is_a?(Hash) && (raw.keys - UNIT_KEYS).empty? && name?(raw["entry"])
          return unless (1..MOST_ROUNDS).any? { raw["rounds"].eql?(it) } && optional?(raw)

          raw.slice(*UNIT_KEYS)
        end

        # Whether a unit's after, if given, is a rule, and its pairing, if
        # given, one of PAIRINGS.
        def optional?(raw)
          (!raw.key?("after") || rule?(raw["after"])) && (!raw.key?("pairing") || PAIRINGS.include?(raw["pairing"]))
        end

        def counterexamples(raw)
          kept = map(raw) { |k, v| REWRITE.match?(k) && v.is_a?(Array) && v.all? { unit(it) } }
          kept&.transform_values { |units| units.map { unit(it) } }
        end

        def index_ideas(raw)
          kept = map(raw) { |k, v| SEARCH.match?(k) && v.is_a?(Hash) }&.transform_values { search(it) }
          kept&.reject { |_, v| v.empty? }
        end

        # One search's rounds and skips.
        def search(rounds)
          kept = ROUNDS.to_h { [it, map(rounds[it]) { |name, counts| name?(name) && counts?(counts) }] }
          kept.merge("skipped" => list(rounds["skipped"]) { skip(it) }).reject { |_, v| v.nil? || v.empty? }
        end

        # A round's counts for written statements whose index_outcomes are
        # outcomes: by outcome, and by rule.
        def tallies(written, outcomes)
          by = ->(key) { outcomes.map { it[key] }.grep(String).tally }
          { "written" => written, "outcomes" => by.call("outcome").slice(*OUTCOMES),
            "rules" => by.call("rule").select { |rule, _| rule?(rule) } }
        end

        def counts?(raw)
          raw.is_a?(Hash) && raw.keys.sort == %w[outcomes rules written] && count?(raw["written"]) &&
            tally?(raw["outcomes"]) { OUTCOMES.include?(it) } && tally?(raw["rules"]) { rule?(it) }
        end

        def tally?(raw, &key) = raw.is_a?(Hash) && raw.all? { |k, v| key.call(k) && count?(v) }

        def skip(raw)
          raw.slice("entry", "rule") if raw.is_a?(Hash) && raw.keys.sort == %w[entry rule] && name?(raw["entry"]) &&
                                        rule?(raw["rule"])
        end

        def list(raw, &) = (raw.filter_map(&) if raw.is_a?(Array))

        def map(raw, &) = (raw.select(&) if raw.is_a?(Hash))

        def name?(value) = value.is_a?(String) && NAME.match?(value)
        def rule?(value) = value.is_a?(String) && RULE.match?(value)
        def count?(value) = value.is_a?(Integer) && !value.negative?
      end
    end
  end
end
