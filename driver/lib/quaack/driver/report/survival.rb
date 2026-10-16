# frozen_string_literal: true

require "quaack/protocol/fuzz_result"
require_relative "format"
require_relative "words"

module Quaack
  module Driver
    module Report
      # Mixed into View: what a rewrite survived, under its SQL (DESIGN.md's
      # report; the user, 2026-10-16, task 20261016-3): the data sets
      # rewrite-test's searches generated, from the payload's counts, then
      # its counterexample rounds, by provider and model, from the driver's
      # own provenance record (Providers#llm_record). A stage that didn't
      # run says nothing.
      module Survival
        # What the rewrite survived of rewrite-test's searches, in the
        # user's words (2026-10-16, task 20261016-3): fuzz's random small
        # databases, then enumerate's, if it compared any, and the bound it
        # finished, if nothing later disproved the rewrite, unless either
        # search proved it wrong, or nil.
        def fuzz_line(entry)
          trials = entry["trials"]
          return unless whole?(trials) && trials.positive? && !Rewrites::SEARCH_FAILED.key?(entry["fate"])

          worlds = entry["worlds"]
          worlds = 0 unless whole?(worlds)
          "#{survivor(entry)} survived #{Words.count(trials + worlds, "mechanically generated data set")} " \
            "trying to show it gives different results from the original query#{enumerated(entry, trials, worlds)}."
        end

        def whole?(number) = number.is_a?(Integer) && number >= 0

        # A rewrite by its name, as a sentence's subject, or by its number without one.
        def survivor(entry) = entry["name"] || called(entry)

        # How the data sets split between fuzz and enumerate, and the bound
        # enumerate finished, or "" when enumerate compared none.
        def enumerated(entry, trials, worlds)
          return "" unless worlds.positive?

          ": #{Words.count(trials, "random one", "random ones")}, then #{Format.number(worlds)} enumerated in " \
            "order of size#{bound_claim(entry)}"
        end

        def bound_claim(entry)
          bound = entry["bound"]
          return "" unless bound.is_a?(Integer) && bound.between?(1, Protocol::FuzzResult::MAX_BOUND) &&
                           !later_disproof?(entry["fate"])

          ", which covered every data set of up to #{Words.count(bound, "row")} over its value classes"
        end

        # Who wrote a rewrite's counterexample rounds, as a sentence, or nil
        # if no round ran. A rewrite no round proved wrong or failed on says
        # what it survived, in the user's words (2026-10-16, task
        # 20261016-3), "also" after the generated data sets it survived.
        def counterexample_line(entry)
          units = llm_record.dig("counterexamples", entry["rewrite"])
          return "Who wrote #{Providers::TEST_DATA}: #{Words::MISSING}." if units.nil? && entry["covered"].is_a?(Array)
          return if units.nil? || units.empty?

          said = ROUND_FATES.include?(entry["fate"]) ? said_units(units) : survived_units(entry, units)
          ["#{said}.", Cautions::PAIRED[pairing(entry)]].compact.join(" ")
        end

        # The fates in which a counterexample round proved the rewrite wrong or failed.
        ROUND_FATES = %w[counterexamples_disproved counterexamples_failed].freeze

        def survived_units(entry, units)
          lead = fuzz_line(entry) ? "It also" : survivor(entry)
          said = "#{lead} survived #{Words.count(units.sum { it["rounds"] }, "round")} of test data meant to break it"
          units.size == 1 ? "#{said} from #{written_by(units.first)}" : "#{said}: #{each_unit(units)}"
        end

        # Each unit's rounds and who wrote them, in order, and why each fresh start began.
        def each_unit(units)
          units.each_with_index.map do |unit, i|
            said = "#{Format.number(unit["rounds"])} from #{written_by(unit)}"
            i.zero? ? said : "then #{said}#{fresh(units[i - 1], unit)}"
          end.join(", ")
        end

        # A unit's provider and its model, from the record.
        def written_by(unit)
          model = llm_providers.find { it["name"] == unit["entry"] }&.fetch("model", nil)
          model ? "#{unit["entry"]} using #{model}" : "#{unit["entry"]} (its model wasn't recorded)"
        end
      end
    end
  end
end
