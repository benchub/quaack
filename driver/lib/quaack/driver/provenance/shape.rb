# frozen_string_literal: true

module Quaack
  module Driver
    class Provenance
      # The checks a record read back passes through: each part is kept
      # only if it has exactly the shape a writer gives it.
      module Shape
        # A unit's keys, and the most rounds a rewrite gets (Counterexamples::ROUNDS).
        UNIT_KEYS = %w[entry rounds after].freeze
        MOST_ROUNDS = 3

        module_function

        def record(raw)
          kept = { "providers" => list(raw["providers"]) { provider(it) }, **rewrites(raw),
                   "counterexamples" => counterexamples(raw["counterexamples"]),
                   "index_ideas" => index_ideas(raw["index_ideas"]) }.reject { |_, v| v.nil? || v.empty? }
          name?(raw["operator_inference"]) ? kept.merge("operator_inference" => raw["operator_inference"]) : kept
        end

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

        # A counterexample unit: its entry, its rounds, one to three, since
        # no rewrite gets more, and, for a fresh start, after, a rule. No
        # other key.
        def unit(raw)
          return unless raw.is_a?(Hash) && (raw.keys - UNIT_KEYS).empty? && name?(raw["entry"])
          return unless (1..MOST_ROUNDS).any? { raw["rounds"].eql?(it) }
          return if raw.key?("after") && !rule?(raw["after"])

          raw.slice(*UNIT_KEYS)
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
