# frozen_string_literal: true

require_relative "../fixed_notes"
require_relative "words"

module Quaack
  module Driver
    module Report
      # The queries section's list of your own rewrites (task 20261021-2):
      # each one the payload's own_rewrites holds, kept or refused. A kept
      # one points at the stored rewrite it became; a refused one shows its
      # text, unless the enclave held it back, and the reason, in the
      # burndown's words (Words::COUNTS) or the rule's fixed note
      # (FixedNotes::BY_RULE, only one written of a rewrite), or else as failing the checks on what goes in.
      module OwnRewriteList
        DROPPED = "QUAACK dropped it before testing it"
        HELD_BACK = "QUAACK held back its text, since it holds a value that isn't one of the original query's " \
                    "placeholders."

        def own_rewrites = Array(@payload["own_rewrites"]).grep(Hash)

        def refused_own = own_rewrites.reject { it["outcome"] == "accepted" }

        def kept_own = own_rewrites.select { it["outcome"] == "accepted" && it["rewrite"] }

        def own_called(entry) = "Your own rewrite #{entry["index"] || Words::MISSING}"

        def own_anchor(entry) = "own-rewrite-#{entry["index"]}"

        # What became of a refused one, as a sentence.
        def own_reason(entry)
          rule = entry["rule"]
          words = Words::COUNTS[rule]
          return "#{DROPPED}: it #{words}." if words

          note = FixedNotes::BY_RULE[rule]
          return "#{DROPPED}. #{note.delete_suffix(" QUAACK dropped it.")}" if rewrite_note?(note)

          "#{DROPPED}: it #{Words::COUNTS.fetch("inbound_check")}."
        end

        def rewrite_note?(note) = note&.start_with?("A rewrite ") && !note.include?("{next}")
      end
    end
  end
end
