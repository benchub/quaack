# frozen_string_literal: true

require_relative "../provenance"
require_relative "format"
require_relative "words"

module Quaack
  module Driver
    module Report
      # Mixed into View: which LLM provider did what (DESIGN.md's "Several
      # LLM providers", Provenance, and report). It reads only the driver's
      # own provenance record and its own call counts, @llm's "record" and
      # "calls" (each provider of this run of quaack, by name, with its
      # calls by step), never anything the enclave sent. Anything the
      # record lacks is "not recorded", never a guess.
      #
      # Tables split the LLM's rows by provider only for a run with more
      # than one, so a lone llm block's report reads as one provider.
      module Providers
        # Why the run left a provider, by rule, for the providers table.
        DOWN = { "llm_rate_limited" => "marked down, since it was rate limited",
                 "llm_unavailable" => "marked down, since it was unavailable",
                 "llm_auth" => "dropped, since its credentials were refused" }.freeze
        # What ended a provider's counterexample rounds, by rule.
        ENDED = { "llm_rate_limited" => "was rate limited", "llm_unavailable" => "was unavailable",
                  "llm_auth" => "had its credentials refused",
                  "llm_bad_response" => "gave a reply QUAACK couldn't use" }.freeze
        TEST_DATA = "the test data meant to break it"
        PER_PROVIDER = "For each provider, only what it proposed and what already existed are recorded. The LLM " \
                       "row has the rest, for every provider together."

        # The record, kept only where it has the shapes a writer gives it.
        def llm_record = @llm_record ||= Provenance::Shape.record(@llm.fetch("record", nil) || {})

        def llm_providers = llm_record.fetch("providers", [])

        # Each provider of this run of quaack, by name, with its calls by step.
        def provider_calls = @llm.fetch("calls", nil) || {}

        # Whether the tables split the LLM's rows by provider.
        def split? = llm_providers.size > 1

        # The recorded provider that wrote an LLM rewrite, or nil.
        def author(entry)
          name = llm_record.dig("rewrites", entry["rewrite"])
          llm_providers.find { it["name"] == name }
        end

        # An LLM rewrite's source, as HTML: "suggested by the LLM (groq,
        # <code>model</code>)".
        def llm_source_html(entry)
          by = author(entry) or return Format.h("suggested by the LLM (its model wasn't recorded)")

          "#{Format.h("suggested by the LLM (#{by["name"]}, ")}<code>#{Format.h(by["model"])}</code>)"
        end

        # Who wrote a rewrite's counterexample rounds, as a sentence, or nil
        # if no round ran.
        def counterexample_line(entry)
          units = llm_record.dig("counterexamples", entry["rewrite"])
          return "Who wrote #{TEST_DATA}: #{Words::MISSING}." if units.nil? && entry["covered"].is_a?(Array)
          return if units.nil? || units.empty?

          ["#{said_units(units)}.", Cautions::PAIRED[pairing(entry)]].compact.join(" ")
        end

        # The LLM rewrites' rows by provider, each kept from kept, under the
        # LLM row, whose proposals were total. Every count in them is not
        # recorded unless the record's proposals add up to total, and then
        # the row for unrecorded authors, all not recorded too, is left out.
        def llm_rewrite_rows(kept, total)
          return [] unless split?

          proposed = llm_record.fetch("rewrites_proposed", {})
          rows = provider_rewrite_rows(kept, proposed)
          rows = rows.reject { it.first == unattributed_name } unless proposed.values.sum == total
          added_up(rows, proposed.values.sum, total)
        end

        # A row per provider that wrote one of kept or proposed some, then
        # one for those of kept whose author the record lacks.
        def provider_rewrite_rows(kept, proposed)
          by = kept.group_by { author(it)&.fetch("name") }
          rows = recorded_names(proposed.keys | by.keys).map { llm_row(it, by.fetch(it, []), proposed[it]) }
          rows + unattributed(by[nil])
        end

        # The row of LLM rewrites whose author the record lacks, if any.
        def unattributed(kept) = kept ? [llm_row(Words::MISSING, kept, nil)] : []
        def unattributed_name = "The LLM: #{Words::MISSING}"

        def llm_row(name, kept, proposed) = ["The LLM: #{name}", *rewrite_counts(kept, proposed)]

        # The LLM indexes' rows by provider: what each wrote and how many of
        # those already existed, over every search and round, when the
        # record's add up to total, the LLM row's; the rest isn't recorded
        # by provider.
        def llm_index_rows(total)
          return [] unless split?

          counts = index_counts
          rows = recorded_names(counts.keys).map { ["The LLM: #{it}", *counts[it], *([nil] * 4)] }
          added_up(rows, counts.values.sum(&:first), total)
        end

        # Each entry in this run's record or calls: its name, provider type,
        # model, calls, and whether the run left it, each nil if not
        # recorded.
        def provider_rows
          (llm_providers.map { it["name"] } | provider_calls.keys).map do |name|
            entry = llm_providers.find { it["name"] == name } || {}
            [name, *entry.values_at("provider", "model"), calls_of(name), left(entry)]
          end
        end

        # The calls table's providers, and whether it has a column for all
        # of them together.
        def call_columns = provider_calls.keys
        def call_total? = call_columns.size != 1

        # name's calls in this run of quaack, or nil if it had none.
        def calls_of(name) = provider_calls[name]&.values&.sum

        # A row per step that called an LLM: its words, each provider's
        # calls, and all of them together.
        def call_rows
          call_steps.map do |step|
            cells = call_columns.map { provider_calls[it].fetch(step, 0) }
            [Words::LLM_STEPS.fetch(step) { Words.plain(step) }, *cells,
             *(@llm_calls.fetch(step) { cells.sum } if call_total?)]
          end
        end

        private

        # Every step that called an LLM, in the order Words lists them.
        def call_steps
          steps = @llm_calls.keys | provider_calls.values.flat_map(&:keys)
          steps.sort_by { Words::LLM_STEPS.keys.index(it) || Words::LLM_STEPS.size }
        end

        # names, of those recorded, in the record's order.
        def recorded_names(names) = llm_providers.map { it["name"] } & names

        # rows by provider, whose counts add up to sum: as they are if
        # that's total, the LLM row's, else with every count not recorded
        # (DESIGN.md, "Several LLM providers": Provenance).
        def added_up(rows, sum, total) = total == sum ? rows : rows.map { |name, *counts| [name, *[nil] * counts.size] }

        # Whether the run marked the recorded entry down or dropped it, and
        # why, or nil if it isn't recorded.
        def left(entry)
          return if entry.empty?
          return "no" unless entry.key?("down")

          DOWN.fetch(entry["down"]) { "left, by rule #{entry["down"]}" }
        end

        # Each provider's statements written and those that already
        # existed, over every search and round of the record.
        def index_counts
          rounds = llm_record.fetch("index_ideas", {}).values.flat_map { it.values_at(*Provenance::ROUNDS).compact }
          rounds.flat_map(&:to_a).group_by(&:first).transform_values do |counts|
            counts.map { |(_, c)| [c["written"], c["rules"].fetch("covered_by_existing", 0)] }.transpose.map(&:sum)
          end
        end

        # "groq wrote the test data meant to break it in round 1, then opus
        # in rounds 2 and 3, starting fresh after groq was rate limited".
        def said_units(units)
          first = 1
          units.each_with_index.map do |unit, i|
            rounds = (first...(first += unit["rounds"])).to_a
            said = "#{unit["entry"]}#{" wrote #{TEST_DATA}" if i.zero?} in #{said_rounds(rounds)}"
            i.zero? ? said : "then #{said}#{fresh(units[i - 1], unit)}"
          end.join(", ")
        end

        def fresh(before, unit)
          return "" unless unit["after"]

          ", starting fresh after #{before["entry"]} #{ENDED.fetch(unit["after"]) { "failed (#{unit["after"]})" }}"
        end

        def said_rounds(rounds)
          return "round #{rounds.first}" if rounds.size == 1
          return "rounds #{rounds.join(" and ")}" if rounds.size == 2

          "rounds #{rounds[0..-2].join(", ")}, and #{rounds.last}"
        end
      end
    end
  end
end
