# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Mixed into View: the cautions on a rewrite. Its summary's warning
      # (DESIGN.md's report), and what its counterexample_pairing came to
      # (DESIGN.md's "Several LLM providers", Adversarial pairing), from
      # the driver's own provenance record (Providers#llm_record).
      module Cautions
        # What a rewrite's counterexample_pairing came to, by outcome, and
        # the summary's warning for those that need one.
        PAIRED = { "met" => "The pairing was met: a different model from the one that wrote the rewrite wrote all " \
                            "its test data.",
                   "not_met" => "The pairing wasn't met: no other provider was left, so the model that wrote the " \
                                "rewrite also wrote test data meant to break it.",
                   "unchecked" => "The pairing couldn't be checked, since the record doesn't say which model wrote " \
                                  "the rewrite." }.freeze
        UNPAIRED = { "not_met" => "a model checked its own work, since the one that wrote it also wrote test data " \
                                  "meant to break it.",
                     "unchecked" => "nothing could check that a different model wrote its test data." }.freeze

        # A hint for a rewrite's summary line, so a collapsed section still
        # shows that it holds a warning: what the rewrite rests on in the
        # data, conditions no test exercised, even later, or a
        # counterexample pairing that wasn't met or couldn't be checked
        # (pairing_warning). nil if none.
        #
        # The open section's body passes body: true. Its empirical paragraph
        # already says the data caution, so the body's warning leaves it out
        # and each caution reads once.
        def warning(entry, body: false)
          said = body ? [] : data_caution(entry)
          said << (said.empty? ? UNPROVEN_FIRST : UNPROVEN_AFTER) if unchecked_atoms(entry).any?
          paired = pairing_warning(entry)
          said << (said.empty? ? paired : paired.sub(/\A./, &:upcase)) if paired
          "Read it with care: #{said.join(" ")}" unless said.empty?
        end

        def data_caution(entry) = empirical(entry) ? ["it relies on what your data holds today."] : []

        UNPROVEN_FIRST = "every test QUAACK ran passed, but the test data never exercised some of its " \
                         "conditions, so those parts are unproven."
        UNPROVEN_AFTER = "The test data also never exercised some of its conditions, so those parts are unproven."

        # The summary's warning about a rewrite's pairing, when it wasn't
        # met or couldn't be checked, or nil.
        def pairing_warning(entry) = UNPAIRED[pairing(entry)]

        # What a rewrite's counterexample_pairing came to, over its units:
        # not_met if any ran on its author, else unchecked, else met, or
        # nil when pairing doesn't apply or wasn't recorded. A rule-made or
        # operator rewrite has no author, so its unchecked is nil.
        def pairing(entry)
          outcomes = Array(llm_record.dig("counterexamples", entry["rewrite"])).map { it["pairing"] }
          found = %w[not_met unchecked met].find { outcomes.include?(it) }
          found unless found == "unchecked" && entry["source"] != "llm"
        end
      end
    end
  end
end
