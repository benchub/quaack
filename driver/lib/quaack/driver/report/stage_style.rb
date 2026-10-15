# frozen_string_literal: true

require "erb"
require_relative "format"

module Quaack
  module Driver
    module Report
      # What the burndown's Sankey diagrams (Sankey) share about a stage:
      # its color, the same in every report, how its record counted, and
      # the words for what it didn't count and what went on untested in time.
      module StageStyle
        BLUE = "var(--st-default)"
        # One color per stage, a CSS variable the template defines for both themes.
        COLORS = {
          "index-from-query" => "var(--st-blue)",
          "index-from-plan" => "var(--st-teal)",
          "index-dedupe" => "var(--st-violet)",
          "index-test" => "var(--st-brown)",
          "llm-index-ideas" => "var(--st-rose)",
          "llm-index-refine" => "var(--st-green)",
          "index-rank" => "var(--st-gold)",
          "rewrite-rules" => "var(--st-blue)",
          "llm-rewrites" => "var(--st-violet)",
          "operator-rewrites" => "var(--st-teal)",
          "assumption-check" => "var(--st-brown)",
          "plan-pruning" => "var(--st-rose)",
          # The only other indigo stage is in the candidates' diagram.
          "fuzz" => "var(--st-indigo)",
          # The only other slate stage is in the candidates' diagram.
          "enumerate" => "var(--st-slate)",
          "rewrite-test" => "var(--st-green)",
          "counterexamples" => "var(--st-gold)",
          "rewrite-index-ideas" => "var(--st-indigo)",
          "measurement" => "var(--st-slate)"
        }.freeze
        NOT_NONE = "This run didn't count it, which doesn't mean none."

        # Words, escaped for an SVG, with any SQL marks dropped, since an
        # SVG <text> can't hold the <code> Format.h sets SQL in.
        def self.text(value) = ERB::Util.html_escape(value.to_s.delete(Format::MARKS))

        # How many rewrites a stage's record carried on though their test
        # didn't finish in time (task 20261011-15's extra
        # not_tested_in_time), or nil for none.
        def self.untimed(record)
          count = record.is_a?(Hash) && record["extra"].is_a?(Hash) ? record["extra"]["not_tested_in_time"] : nil
          count if count.is_a?(Integer) && count.positive?
        end

        # How many rewrites fuzz's record carried on though the search
        # couldn't test them (task 20261012-4's extra untested), or nil for
        # none. enumerate's untested ones passed fuzz.
        def self.untested(record, stage)
          return unless stage == "fuzz" && record.is_a?(Hash) && record["extra"].is_a?(Hash)

          count = record["extra"]["untested"]
          count if count.is_a?(Integer) && count.positive?
        end

        CHECKED_ONLY = "went on, checked only on the LLM's test data and the real data."

        # The notes a stage with rewrites that went on untested gets in its
        # hover: those not tested in time, and those the search couldn't test.
        def self.went_on_notes(record, stage)
          untimed = untimed(record)
          untested = untested(record, stage)
          [untimed && "#{Format.number(untimed)} not tested in time on made-up data #{CHECKED_ONLY}",
           untested && "#{Format.number(untested)} not tested on made-up data #{CHECKED_ONLY}"].compact
        end

        # A record's [in, out], [in, nil] if it has no out, or [nil, nil] if
        # it has no count of what came in, or a count that can't be one.
        def self.counted(record)
          inn, out = record&.values_at("in", "out")
          return [nil, nil] unless count?(inn)

          return [inn, nil] if out.nil?

          count?(out) ? [inn, out] : [nil, nil]
        end

        def self.count?(count) = count.is_a?(Integer) && !count.negative?
      end
    end
  end
end
