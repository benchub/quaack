# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # The "Who proposed it" cell of the "Measured, and not ranked" table
      # (DESIGN.md's report): who proposed the label's rewrite, then
      # "indices:" and the sources that proposed the new indexes it ran with,
      # from each entry's sources in the payload's indexes.
      #
      #   proposers("rewrite_1:top:1", "made by transform rule x")
      #   # => "Made by transform rule x; indexes: from the query's text, from the LLM"
      #   proposers("rewrite_1:shared:1", "made by transform rule x")
      #   # => "Made by transform rule x; indices: from another candidate, which had them from the LLM"
      module IndexProposers
        # How each index source reads, by the names Protocol::IndexSources::SOURCES gives it.
        INDEX_SOURCES = { "generator_one" => "from the query's text", "generator_two" => "from the query's plan",
                          "llm" => "from the LLM" }.freeze

        # who is the rewrite's source in words, or nil for the original
        # query or a rewrite whose source isn't recorded. The cell says
        # nothing more for a label with no new indexes, or one the payload
        # doesn't list. Where only some of the label's indexes have a
        # recorded source, the cell ends "and others not recorded". Where none
        # of them has one, as in a run from an older enclave, the indexes are "not
        # recorded", and a cell with nothing else is nil, which the table
        # shows as not recorded.
        def proposers(label, who)
          names = measured(label)&.fetch("indexes", nil)
          return who && Words.upper(who) if names.to_a.empty?

          found = index_sources_of(names)
          return shared(who, found, names) if shared?(label)
          return Words.upper([who, "indices: #{listed(found, names)}"].compact.join("; ")) unless found.empty?

          who && Words.upper("#{who}; indices: #{Words::MISSING}")
        end

        # Whether the label is a shared pairing (DESIGN.md's index-share):
        # it ran with indices another candidate's search ranked.
        def shared?(label) = label.to_s.split(":")[1] == "shared"

        # A shared pairing's cell: its indices came from another candidate,
        # which had them from its recorded sources, if any are recorded.
        def shared(who, found, names)
          from = "from another candidate"
          from += ", which had them from #{listed(found, names).delete_prefix("from ")}" unless found.empty?
          Words.upper([who, "indices: #{from}"].compact.join("; "))
        end

        # The found sources, then "and others not recorded" if any named index has none recorded.
        def listed(found, names)
          unrecorded = names.any? { Array(indexes.dig(it, "sources")).empty? }
          unrecorded ? "#{found.join(", ")} and others #{Words::MISSING}" : found.join(", ")
        end

        # The sources of the named indexes, in words, once each, in the protocol's order.
        def index_sources_of(names)
          given = names.flat_map { Array(indexes.dig(it, "sources")) }
          (INDEX_SOURCES.keys & given).map { INDEX_SOURCES[it] }
        end
      end
    end
  end
end
