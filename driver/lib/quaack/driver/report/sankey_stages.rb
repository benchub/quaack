# frozen_string_literal: true

require_relative "format"
require_relative "words"
require_relative "stage_sentences"
require_relative "funnel"
require_relative "sankey_layout"

module Quaack
  module Driver
    module Report
      # What a Sankey diagram draws for each stage (see Sankey): a node from
      # the stage's record, a source for each name in its added, and a sink
      # for each of its drop reasons and what it set aside for testing during
      # ranking. Its words are the funnel's and the table's. A stage that adds
      # always shows its source, with a zero when it added nothing (ZERO).
      module SankeyStages
        SET_ASIDE = "Set aside for testing during ranking"
        # Each adding stage's source, by the name its added counts it under.
        ZERO = { "index-from-query" => "generator_one", "index-from-plan" => "generator_two",
                 "llm-index-ideas" => "llm", "llm-index-refine" => "llm", "index-rank" => "combinations",
                 "rewrite-rules" => "rules", "llm-rewrites" => "llm", "operator-rewrites" => "operator" }.freeze

        private

        def sankey_stage(index, name, record, stage, of_rewrite)
          inn, out = funnel_counted(record)
          state = sankey_state(inn, out)
          sentence = StageSentences.for(stage, of_rewrite:)
          sources, sinks = state == :unknown ? [[], []] : sankey_flows(record, stage, sentence)
          SankeyParts::Stage.new(id: "n#{index}", kind: :stage, name:, state:, inn:, out:, sources:, sinks:,
                                 color: Funnel::COLORS.fetch(stage, Funnel::BLUE), keys: [stage],
                                 sentences: [sentence].compact)
        end

        # Whether the run counted all, only what came in, or none of the stage.
        def sankey_state(inn, out)
          return :unknown if inn.nil?

          out.nil? ? :partial : :full
        end

        # The node's hover: a note for a stage the run didn't fully record,
        # then the stage's sentence, then the stage's own numbers.
        def sankey_tip(node)
          note = { unknown: "#{node.name}: #{Words::MISSING}. #{Funnel::NOT_NONE}",
                   partial: "How many went on: #{Words::MISSING}. #{Funnel::NOT_NONE}" }[node.state]
          numbers = node.state == :unknown ? [] : sankey_numbers(node)
          [note, *node.sentences, *numbers].compact.join(" ")
        end

        def sankey_numbers(node)
          held, dropped = node.sinks.partition { it.kind == :held }
          counts = { "came in" => node.inn, "added" => node.sources.sum(&:amount),
                     "dropped" => dropped.sum(&:amount), "set aside for testing during ranking" => held.sum(&:amount),
                     "went on" => node.out }
          told = counts.select { |word, count| sankey_shown?(word, count) }
          told.map { |word, count| "#{Format.number(count)} #{word}." }
        end

        # A count is told if there is one, and it counted something or is what went on.
        def sankey_shown?(word, count) = count.is_a?(Integer) && (count.positive? || word == "went on")

        # A record's [sources, sinks].
        def sankey_flows(record, stage, sentence)
          [sankey_sources(record, stage, sentence), sankey_sinks(record, stage, sentence)]
        end

        # A source for each name in a record's added, in order, or the stage's own
        # source at zero if it has one and added nothing.
        def sankey_sources(record, stage, sentence)
          counted = sankey_counted(record["added"])
          counted = { ZERO[stage] => 0 } if counted.empty? && ZERO.key?(stage)
          counted.map { |name, count| sankey_flow(sankey_source_words(name, stage, count), count, :source, sentence) }
        end

        def sankey_source_words(name, stage, count)
          rules = stage == "rewrite-rules"
          words = rules && count.zero? ? "from the transform rules" : counted_as(name, rules, stage)
          Words.upper(words)
        end

        # A sink for each drop reason, then one for what the stage set aside.
        def sankey_sinks(record, stage, sentence)
          sinks = sankey_counted(record["dropped"]).map do |name, count|
            sankey_flow("Dropped, #{counted_as(name, false, stage)}", count, :drop, sentence)
          end
          held = sankey_counted({ "held" => record["set_aside"] }).fetch("held", 0)
          sinks << sankey_flow(SET_ASIDE, held, :held, sentence) if held.positive?
          sinks
        end

        # The counts that counted something, in order.
        def sankey_counted(counts) = counts.to_h.select { |_, count| count.is_a?(Integer) && count.positive? }

        def sankey_flow(label, amount, kind, sentence)
          text = "#{label}: #{Format.number(amount)}"
          SankeyParts::Flow.new(label: text, amount:, kind:, tip: [sentence, "#{text}."].compact.join(" "))
        end
      end
    end
  end
end
