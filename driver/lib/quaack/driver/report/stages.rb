# frozen_string_literal: true

require_relative "stage_sentences"

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

        # The rewrite stages, each summed over its searches. The rewrites'
        # own index searches count index ideas, not rewrites, so they're
        # their own table (rewrite_index_rows). A run from before fuzz
        # (task 20261012-2) recorded rewrite-test but never fuzz, so it
        # gets no fuzz row; one from before enumerate (20261012-3), none
        # for it. The search replaced rewrite-test's scenarios (20261012-4),
        # so only a run from before that gets a rewrite-test row.
        def rewrite_rows = summed(rewrite_stages) + summed(Words::LATE_STAGES)

        def rewrite_stages
          stages = burndown["stages"]
          return Words::REWRITE_STAGES.except("rewrite-test") unless stages.key?("rewrite-test")

          Words::REWRITE_STAGES.except(*%w[fuzz enumerate].reject { stages.key?(it) })
        end

        # The rewrites' own index searches, totaled per stage.
        def rewrite_index_rows = search_rows

        def summed(stages) = stages.map { |stage, name| [name, sum(burndown["stages"].fetch(stage, {}).values), stage] }

        def search_rows
          searched = rewrite_searches
          rows = Words::INDEX_STAGES.filter_map do |stage, name|
            found = searched.fetch(stage).values
            ["Index ideas for the rewrites: #{Words.lower(name)}", sum(found), stage] unless found.empty?
          end
          rows.empty? ? [["Index ideas for the rewrites", nil, nil]] : rows
        end

        # The LLM's rounds of index ideas, which run only for the rewrites that survived testing.
        LLM_ROUNDS = %w[llm-index-ideas llm-index-refine].freeze

        # Each index stage's records of the rewrites' searches. The LLM searches only the
        # rewrites that survived testing, but index-rank ranks every one, so a rewrite the
        # LLM wasn't asked about passes its ideas through the LLM's rounds unchanged
        # (PASSED), and each row's sum carries on what the row above sent (task 20261017-8).
        def rewrite_searches
          stages = Words::INDEX_STAGES.keys.to_h { [it, burndown["stages"].fetch(it, {}).except("original")] }
          asked = LLM_ROUNDS.flat_map { stages.fetch(it).keys }
          stages.values.flat_map(&:keys).uniq.reject { asked.include?(it) }.each { pass_through(stages, it) }
          stages
        end

        # The search's ideas, through each LLM round some other search recorded.
        def pass_through(stages, search)
          carried = nil
          stages.each do |stage, records|
            next carried = records[search]["out"] if records.key?(search)

            records[search] = passed(carried) if LLM_ROUNDS.include?(stage) && records.any? && carried.is_a?(Integer)
          end
        end

        def passed(count)
          { "in" => count, "added" => {}, "dropped" => {}, "set_aside" => 0, "out" => count,
            "extra" => { PASSED => count } }
        end

        # The extra count of the ideas a rewrite the LLM wasn't asked about passed on.
        PASSED = "not_asked"

        # The records added together, or nil if there are none.
        def sum(records)
          records.reduce do |a, b|
            a.merge(b) { |_, x, y| x.is_a?(Hash) ? x.merge(y) { |_, m, n| m + n } : x + y }
          end
        end

        # The row's tooltip, an attribute for its <tr>: what its stage does.
        # A row with no stage, or one with no sentence, gets none.
        def stage_tip(stage, of_rewrite: false)
          sentence = StageSentences.for(stage, of_rewrite:)
          sentence ? %( title="#{h(sentence)}") : ""
        end

        # A record's added, dropped, or extra counts in words, leaving out
        # a name that counted nothing. rewrite-rules adds by rule, and names the rule.
        # stage is the record's, for the names whose words depend on it
        # (counted); words, any names its stage words its own way.
        def breakdown(counts, rules: false, stage: nil, words: {})
          counted = counts.reject { |_, n| n.to_i.zero? }
          return "none" if counted.empty?

          counted.map { |name, n| "#{words[name] || counted_as(name, rules, stage)}: #{Format.number(n)}" }.join("; ")
        end

        def counted_as(name, rule, stage) = rule ? "by the transform rule #{name}" : counted(name, stage)

        # A name in words. An older run's rewrite-test (from before task
        # 20261012-4) dropped a rewrite by the scenario that disproved it,
        # s0 to s6, said without naming the scenario, or one it never tested
        # by the rule of the refusal or the failure, said as the rewrite's
        # fate says it; any rule it has no words for is a statement that
        # failed. fuzz and enumerate drop one by the comparison's rule.
        def counted(name, stage)
          return fuzz_drop(name, stage) if SEARCH_DROPS.key?(stage) && !Words::COUNTS.key?(name)
          return Words::COUNTS.fetch(name) { Words.plain(name) } unless stage == "rewrite-test" &&
                                                                        !Words::COUNTS.key?(name)

          legacy_test_drop(name)
        end

        def legacy_test_drop(name)
          return "wrong on made-up test data" if SCENARIO.match?(name)

          "never tested, because #{Words::REFUSALS.fetch(name) { Words::FAILURES.fetch(name, Words::FAILED) }}"
        end

        SCENARIO = /\As\d\z/

        SEARCH_DROPS = { "fuzz" => "a random small database",
                         "enumerate" => "a small database QUAACK enumerated" }.freeze

        def fuzz_drop(rule, stage)
          why = rule == "query_failed" ? Words::FUZZ_FAILED : Words::MISMATCHES[rule]
          "wrong on #{SEARCH_DROPS.fetch(stage)}#{", where #{why}" if why}"
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
