# frozen_string_literal: true

require "quaack/protocol/index_sources"
require_relative "../index_candidate"
require_relative "../index_store"

module Quaack
  module Enclave
    module Steps
      # ReportPayload's index_sources (DESIGN.md's report): for each of
      # QUAACK's index sources, how many of the indexes index-build built
      # it proposed, how many of those were not better, how many were
      # ranked, and how many of its candidates already existed or the
      # planner ignored (drops).
      #
      #   IndexSources.call(store, labels, selection)
      #   # => { "generator_one" => { "built" => 2, "not_better" => 0, "ranked" => 1,
      #   #                            "existed" => 1, "ignored" => 3 },
      #   #      "generator_two" => { ... }, "llm" => { ... } }
      #
      # A built index's sources are those of every candidate with its
      # definition that any search's index_search_<search> holds: the
      # Dedupe's proposals and set-aside candidates, whose sources it merged
      # when a later generator or LLM round repeated them, index-test's set-aside
      # ones, and the tested ones. So an index more than one source proposed,
      # in one search or several, counts under each. One no search holds
      # counts under none.
      #
      # Ranked and not better are as the driver's report counts them for
      # every source together: ranked if a ranked label ran with it, not
      # better if at least one measured label ran with it and selection
      # excluded every one as not_better.
      #
      # Trust boundary. Only counts, under the names of NAMES, which are
      # Protocol::IndexSources::SOURCES. A stored source that isn't one of
      # NAMES' keys, such as :existing, counts nowhere and is never sent.
      module IndexSources
        # Each candidate source (IndexCandidate#sources) and the name it's
        # counted under.
        NAMES = { parse: "generator_one", plan: "generator_two", llm: "llm" }.freeze

        module_function

        # labels is MeasuredLabels'.
        def call(store, labels, selection)
          built = sources(store)
          outcomes = [ranked(labels, selection["top"]), not_better(labels, selection["excluded"], built.keys)]
          dropped = drops(store)
          NAMES.values.to_h do |source|
            [source, counts(built.select { _2.include?(source) }.keys, *outcomes).merge(tally(dropped, source))]
          end
        end

        def tally(dropped, source) = dropped.transform_values { it.count { |names| names.include?(source) } }

        # Each search's dropped candidates, as the names of their sources:
        # "existed", index-dedupe's drops as covered by an existing index,
        # and "ignored", index-test's results (the generators' and the LLM
        # rounds') that the planner never used, that HypoPG refused, or that
        # couldn't be rendered, but not the unused ones set aside for
        # index-build. Once per search, as the burndown counts them.
        def drops(store)
          entries = searches(store).map { store.read("index_search_#{it}") }
          { "existed" => entries.flat_map { existed(it) }, "ignored" => entries.flat_map { ignored(it) } }
        end

        def existed(entry)
          entry.dig("dedupe", "drops").to_a.filter_map do |drop|
            names(drop["candidate"]) if drop["reason"] == "covered_by_existing"
          end
        end

        def ignored(entry)
          set_aside = entry.fetch("set_aside", []).map { IndexStore.candidate(it) }
          (entry.fetch("results", []) + entry.fetch("llm_results", [])).filter_map do |result|
            names(result["candidate"]) if result["refusal"] || !kept?(result, set_aside)
          end
        end

        def kept?(result, set_aside)
          used = result["plans"].to_h.values.any? { it["used"] }
          used || set_aside.include?(IndexStore.candidate(result["candidate"]))
        end

        def names(plain) = IndexStore.candidate(plain).sources.filter_map { NAMES[it] }

        def counts(names, ranked, not_better)
          { "built" => names.size, "not_better" => (names & not_better).size, "ranked" => (names & ranked).size }
        end

        # Each built index's name and the names of the sources that proposed it.
        def sources(store)
          proposed = candidates(store)
          store.read("index_build")["indexes"].transform_values do |built|
            candidate = IndexCandidate.from_ddl(built["ddl"], sources: [])
            ((candidate && proposed[candidate]) || Set.new).filter_map { NAMES[it] }
          end
        end

        # Every search's candidates, each with the sources of all its copies.
        # IndexCandidate's equality ignores sources, so copies share a key.
        def candidates(store)
          searches(store).each_with_object({}) do |search, out|
            plains(store.read("index_search_#{search}")).each do |plain|
              candidate = IndexStore.candidate(plain)
              out[candidate] = (out[candidate] || Set.new) | candidate.sources
            end
          end
        end

        def plains(entry)
          dedupe = entry.fetch("dedupe", {})
          tested = entry.fetch("results", []) + entry.fetch("llm_results", [])
          dedupe.fetch("proposals", []) + dedupe.fetch("set_aside", []) + entry.fetch("set_aside", []) +
            tested.filter_map { it["candidate"] }
        end

        def searches(store)
          rewrites = (1..).lazy.take_while { store.entry?("rewrite_#{it}") }.map { "rewrite_#{it}" }.to_a
          (["original"] + rewrites).select { store.entry?("index_search_#{it}") }
        end

        def ranked(labels, top)
          ranked = top.map { it["label"] }
          labels.select { ranked.include?(it["label"]) }.flat_map { it["indexes"] }.uniq
        end

        def not_better(labels, excluded, names)
          names.select do |name|
            ran = labels.select { it["indexes"].include?(name) }
            !ran.empty? && ran.all? { excluded[it["label"]] == "not_better" }
          end
        end
      end
    end
  end
end
