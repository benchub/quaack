# frozen_string_literal: true

require_relative "words"
require_relative "sankey_parts"

module Quaack
  module Driver
    module Report
      # What a Sankey diagram's layers are called (see SankeyLayers).
      module SankeyLayerWords
        # What each adding stage's merge layer is called.
        MERGED = {
          "index-from-query" => "Index ideas from the query's text",
          "index-from-plan" => "Index ideas from the query's text and plan",
          "llm-index-ideas" => "Combined with new ideas from the LLM",
          "llm-index-refine" => "Combined with the LLM's second round of ideas",
          "index-rank" => "Index sets to try",
          "rewrite-rules" => "Rewrites from the transform rules",
          "llm-rewrites" => "Combined with rewrites from the LLM",
          "operator-rewrites" => "Combined with your own rewrites"
        }.freeze
        # What the layer after each stage's drops is called.
        AFTER = {
          "index-from-query" => "After checking the ideas from the query's text",
          "index-from-plan" => "After checking the ideas from the query's plan",
          "index-dedupe" => "After removing duplicates and indexes you already have",
          "index-test" => "After testing for planner utility",
          "llm-index-ideas" => "After testing the LLM's ideas",
          "llm-index-refine" => "After the LLM's second round of ideas",
          "index-rank" => "After trying indexes together",
          "rewrite-rules" => "After removing duplicate rule rewrites",
          "llm-rewrites" => "After checking the LLM's rewrites",
          "operator-rewrites" => "After checking your own rewrites",
          "assumption-check" => "After checking what each rewrite assumes",
          "plan-pruning" => "After checking each rewrite runs differently",
          "fuzz" => "After testing on random small databases",
          "rewrite-test" => "After testing on made-up edge-case data",
          "counterexamples" => "After testing on data the LLM wrote to break them",
          "rewrite-index-ideas" => "Candidates after choosing indexes for each rewrite",
          "measurement" => "Candidates after measuring on the real data"
        }.freeze
        # What a merge layer of a run of stages is called.
        RUNS = {
          %w[index-from-query index-from-plan] => "Mechanical index ideas",
          %w[llm-index-ideas llm-index-refine] => "Index ideas with the LLM's",
          %w[rewrite-rules llm-rewrites] => "Rewrites from the transform rules and the LLM",
          %w[llm-rewrites operator-rewrites] => "Rewrites from the LLM and your own",
          %w[rewrite-rules llm-rewrites operator-rewrites] => "Rewrites from every source"
        }.freeze
      end

      # The layers and steps of a Sankey diagram (see Sankey).
      #
      # A layer is a state: what has made it this far, as wide as its count. A step
      # is the transition from one layer to the next, labelled with the stage's name,
      # with its drops leaving to the right. A stage that adds is a merge layer, as
      # wide as what came in plus what it added; if it also drops, or set anything
      # aside, a step leads from it to the layer after. A stage that only drops is a
      # step and the layer after it. A run of stages that only add is one merge
      # layer with several sources. What a diagram set aside for testing during
      # ranking is a layer of its own at the bottom.
      #
      # A layer's label is fixed words of QUAACK's own and its count, never
      # anything from the data.
      #
      # Its geometry is SankeyLayout's; each step's methods count several ends at once.
      # rubocop:disable-next Metrics/AbcSize
      module SankeyLayers
        P = SankeyParts
        include SankeyLayerWords

        private

        # The stages, with each run of stages that only add merged into one.
        def sankey_runs(stages)
          stages.each_with_object([]) do |stage, merged|
            merged.last && sankey_merge?(merged.last, stage) ? sankey_merge(merged.last, stage) : merged << stage
          end
        end

        # Whether the next stage joins the run so far.
        def sankey_merge?(run, stage)
          [run, stage].all? { sankey_adds_only?(it) } && stage.inn == run.out
        end

        def sankey_adds_only?(stage) = stage.state == :full && stage.sinks.empty? && stage.added.positive?

        # The run, with the stage's sources and what it sent on.
        def sankey_merge(run, stage)
          run.sources += stage.sources
          run.out = stage.out
          run.keys += stage.keys
          run.sentences += stage.sentences
          run.name = "#{run.name}; #{stage.name}"
        end

        # The [layers, steps] for a diagram: start is the layer of what the diagram above
        # sent, or nil; after is whether a diagram follows.
        def sankey_states(stages, start, after:)
          @sankey_layers = [start].compact
          @sankey_steps = []
          sankey_runs(stages).each { sankey_layers_of(it) }
          sankey_went_below if after
          sankey_held
          [@sankey_layers, @sankey_steps]
        end

        def sankey_layers_of(node)
          return sankey_unknown(node) if node.state == :unknown

          sankey_merge_layer(node) if node.sources.any?
          sankey_after(node) if node.sinks.any? || node.sources.empty? || node.state == :partial
        end

        def sankey_last = @sankey_layers.last

        # A stage the run didn't record: a grey layer, with a grey carry from the one before.
        def sankey_unknown(node)
          base = MERGED.fetch(node.keys.last) { AFTER.fetch(node.keys.last, node.name) }
          from = sankey_last
          layer = sankey_layer(node, :after, nil, "#{base}: #{Words::MISSING}", state: :unknown)
          sankey_step(node, from, layer, nil, [from&.total, nil])
        end

        def sankey_merge_layer(node)
          count = node.inn.to_i + node.added
          base = RUNS.fetch(node.keys) { MERGED.fetch(node.keys.last, node.name) }
          from = sankey_last
          layer = sankey_layer(node, :merge, count, "#{base}: #{Format.number(count)}", sources: node.sources,
                                                                                        spread: from.nil?)
          sankey_step(node, from, layer, nil, [from&.total, node.inn])
        end

        def sankey_after(node)
          went = node.state == :full ? node.out : nil
          words = went ? Format.number(went) : Words::MISSING
          from = sankey_last
          layer = sankey_layer(node, :after, went, "#{AFTER.fetch(node.keys.last, node.name)}: #{words}",
                               state: went ? :full : :partial)
          return unless from

          top = (from.total || (node.inn.to_i + node.added)) - node.sinks.sum(&:amount)
          step = Words.upper(node.name.delete_prefix("Index ideas for the rewrites: "))
          sankey_step(node, from, layer, step, [[top, 0].max, went], node.sinks)
        end

        # A new layer, after the last one.
        def sankey_layer(node, role, count, line, state: :full, sources: [], spread: false) # rubocop:disable Metrics/ParameterLists
          P::Layer.new(id: "n#{@sankey_layers.size}", role:, name: node.name, state:, total: count, line:,
                       tip: sankey_tip(node), color: node.color, sources:, spread:).tap { @sankey_layers << it }
        end

        # The step from the layer before, from, into layer, if there is one before.
        def sankey_step(node, from, layer, line, counts, sinks = []) # rubocop:disable Metrics/ParameterLists
          return unless from

          held, drops = sinks.partition { it.kind == :held }
          went = counts[1] || counts[0]
          @sankey_steps << P::Step.new(
            id: "s#{@sankey_steps.size}", from:, into: layer, line:, top: counts[0], bottom: counts[1], drops:, held:,
            grey: from.grey? || layer.state == :unknown || counts.any?(&:nil?),
            carry_tip: [*node.sentences, ("#{Format.number(went)} went on." if went)].compact.join(" ")
          )
        end

        def sankey_went_below
          last = @sankey_layers.reverse.find(&:total) or return
          last.tip = "#{last.tip} #{Format.number(last.total)} went on to the diagram below."
        end

        # The layer of what the diagram set aside, at the bottom, if it set anything aside.
        def sankey_held
          held = @sankey_steps.sum { |step| step.held.sum(&:amount) }
          return unless held.positive?

          words = "#{SankeyStages::SET_ASIDE}: #{Format.number(held)}"
          @sankey_layers << P::Layer.new(id: "held", role: :held, name: SankeyStages::SET_ASIDE, state: :full,
                                         total: held, line: words, tip: "#{words}.", color: nil, sources: [],
                                         spread: false)
        end
      end
    end
  end
end
