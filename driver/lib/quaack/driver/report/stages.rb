# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # DESIGN.md's burndown, the burndown: the payload's stage records and work
      # totals, and the driver's own LLM calls, in words.
      #
      # Every stage of burndown's two tables gets a row. A row is [name, record,
      # stage], and its record is nil for a stage the run didn't record,
      # which the report shows as "not recorded". So a stage that's
      # recorded later shows up without a change here.
      module Stages
        EMPTY = { "stages" => {}, "totals" => {} }.freeze

        # The recorded counts, { "stages", "totals" }.
        def burndown = @payload["burndown"] || EMPTY

        # The original query's index search, one row per stage.
        def index_rows
          Words::INDEX_STAGES.map { |stage, name| [name, burndown["stages"].dig(stage, "original"), stage] }
        end

        # The rewrite stages, each summed over its searches, with the
        # rewrites' own index searches (plan-pruning and rewrite-index-ideas) totaled per stage
        # between counterexamples and rewrite-index-ideas.
        def rewrite_rows = summed(Words::REWRITE_STAGES) + search_rows + summed(Words::LATE_STAGES)

        def summed(stages) = stages.map { |stage, name| [name, sum(burndown["stages"].fetch(stage, {}).values), stage] }

        def search_rows
          rows = Words::INDEX_STAGES.filter_map do |stage, name|
            found = burndown["stages"].fetch(stage, {}).except("original").values
            ["Index ideas for the rewrites: #{Words.lower(name)}", sum(found), stage] unless found.empty?
          end
          rows.empty? ? [["Index ideas for the rewrites", nil, nil]] : rows
        end

        # The records added together, or nil if there are none.
        def sum(records)
          records.reduce do |a, b|
            a.merge(b) { |_, x, y| x.is_a?(Hash) ? x.merge(y) { |_, m, n| m + n } : x + y }
          end
        end

        # A record's added, dropped, or extra counts in words, leaving out
        # a name that counted nothing. rewrite-rules adds by rule, and names the rule.
        def breakdown(counts, rules: false)
          counted = counts.reject { |_, n| n.to_i.zero? }
          return "none" if counted.empty?

          counted.map { |name, n| "#{counted_as(name, rules)}: #{Format.number(n)}" }.join("; ")
        end

        def counted_as(name, rule) = rule ? "by the rule #{name}" : Words::COUNTS.fetch(name) { Words.plain(name) }

        # The driver's LLM calls, by what each was for.
        def llm_lines
          return ["No LLM calls were counted in this run."] if @llm_calls.empty?

          @llm_calls.map do |step, calls|
            "#{Words::LLM_STEPS.fetch(step) { Words.plain(step) }}: #{Words.count(calls.to_i, "call")}"
          end
        end

        # burndown's work totals, each always listed, then any other the enclave
        # counted.
        def total_lines
          totals = burndown["totals"]
          others = totals.except(*Words::TOTALS.keys).to_h { |key, _| [key, Words.plain(key).capitalize] }
          Words::TOTALS.merge(others).map do |key, name|
            "#{name}: #{totals.key?(key) ? Format.number(totals[key]) : Words::MISSING}"
          end
        end
      end
    end
  end
end
