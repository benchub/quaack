# frozen_string_literal: true

module Quaack
  module Driver
    class Provenance
      # How a step's outcomes map back to the entries that wrote what they
      # judge: by position in the input, which each outcome gives as its
      # 1-based index, since rewrite-check and index-test answer one outcome
      # per input, in order. That's how a fan-out step's union maps back to
      # its branches (DESIGN.md, "Several LLM providers": Provenance).
      module Branches
        module_function

        # The entry at index, 1-based, in entries, or nil.
        def at(entries, index) = (entries[index - 1] if index.is_a?(Integer) && index.between?(1, entries.size))

        # Each stored rewrite's store name, from outcomes, its
        # rewrite_outcomes, with the entry that wrote it.
        def stored(outcomes, entries)
          outcomes.select { it["rewrite"].is_a?(String) }.to_h { [it["rewrite"], at(entries, it["index"])] }
        end

        # Each entry of entries, with how many inputs it wrote and the
        # outcomes for them: [[entry, written, outcomes], ...].
        def split(entries, outcomes)
          entries.tally.map do |entry, written|
            [entry, written, outcomes.select { at(entries, it["index"]) == entry }]
          end
        end
      end
    end
  end
end
