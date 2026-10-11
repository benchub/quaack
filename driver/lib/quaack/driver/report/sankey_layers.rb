# frozen_string_literal: true

require_relative "words"

module Quaack
  module Driver
    module Report
      # The layers of a Sankey diagram (see Sankey): the stages, with each run of
      # stages that only add merged into one layer, and each layer's label.
      #
      # A layer is the flow after a stage, so its label reads as the state after it:
      # fixed words of QUAACK's own, and the layer's count at the end, never anything
      # from the data. Several sources can join one layer, as several sinks can leave
      # one. Stages merge only when each one counted in full, added something, has no
      # drop and no held back of its own, and takes in just what the one before it
      # sent on. A stage with a sink of its own never merges, since that would show
      # its sinks taking from what a later stage added.
      module SankeyLayers
        # What each stage's layer is called, as the state after it.
        LABELS = {
          "index-from-query" => "Index ideas from the query's text",
          "index-from-plan" => "Index ideas from the query's text and plan",
          "index-dedupe" => "After removing duplicates and indexes you already have",
          "index-test" => "After testing for planner utility",
          "llm-index-ideas" => "Combined with new ideas from the LLM",
          "llm-index-refine" => "After the LLM's second round of ideas",
          "index-rank" => "After trying indexes together",
          "rewrite-rules" => "Rewrites from the transform rules",
          "llm-rewrites" => "Combined with rewrites from the LLM",
          "operator-rewrites" => "Combined with your own rewrites",
          "assumption-check" => "After checking what each rewrite assumes",
          "plan-pruning" => "After checking each rewrite runs differently",
          "rewrite-test" => "After testing on made-up edge-case data",
          "counterexamples" => "After testing on data the LLM wrote to break them",
          "rewrite-index-ideas" => "Candidates after choosing indexes for each rewrite",
          "measurement" => "Candidates after measuring on the real data"
        }.freeze
        # What a layer of merged stages is called.
        RUNS = {
          %w[index-from-query index-from-plan] => "Mechanical index ideas",
          %w[llm-index-ideas llm-index-refine] => "Index ideas with the LLM's",
          %w[rewrite-rules llm-rewrites] => "Rewrites from the transform rules and the LLM",
          %w[llm-rewrites operator-rewrites] => "Rewrites from the LLM and your own",
          %w[rewrite-rules llm-rewrites operator-rewrites] => "Rewrites from every source"
        }.freeze

        private

        # The layers for a diagram's stages, in order, numbered.
        def sankey_layers(stages)
          layers = stages.each_with_object([]) do |stage, merged|
            merged.last && sankey_merge?(merged.last, stage) ? sankey_merge(merged.last, stage) : merged << stage
          end
          layers.each_with_index { |layer, index| layer.id = "n#{index}" }.map { sankey_words(it) }
        end

        # Whether the next stage joins the layer so far.
        def sankey_merge?(layer, stage)
          [layer, stage].all? { sankey_adds_only?(it) } && stage.inn == layer.out
        end

        def sankey_adds_only?(stage) = stage.state == :full && stage.sinks.empty? && stage.sources.any?

        # The layer, with the stage's sources and what it sent on.
        def sankey_merge(layer, stage)
          layer.sources += stage.sources
          layer.out = stage.out
          layer.keys += stage.keys
          layer.sentences += stage.sentences
          layer.name = "#{layer.name}; #{stage.name}"
        end

        # A layer's label, with its count at the end.
        def sankey_label(node)
          base = RUNS.fetch(node.keys) { LABELS.fetch(node.keys.last, node.name) }
          "#{base}: #{node.state == :full ? Format.number(node.out) : Words::MISSING}"
        end
      end
    end
  end
end
