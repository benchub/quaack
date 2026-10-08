# frozen_string_literal: true

require_relative "error"

module Quaack
  module Driver
    module LLM
      # llm-counterexamples' adversarial pairing for one rewrite (DESIGN.md,
      # "Several LLM providers": Adversarial pairing): mode, the
      # counterexample_pairing; author, the rewrite's recorded author, a
      # Hash with its name and model, or nil if none was recorded; avoid,
      # the names of the entries that count as its author: the one it
      # names, and any with its model; and label, such as "Rewrite Silver
      # Fox", for the failure that names the rewrite. Router#pairing builds
      # one, and a Router::Session keeps its unit off avoid by it.
      Pairing = Data.define(:mode, :author, :avoid, :label) do
        # The Pairing under mode for a rewrite whose recorded author is
        # author, or nil, among the entries of models, each entry's model
        # by name.
        def self.for(mode, author, models, label:)
          avoid = author ? models.keys.select { it == author["name"] || author["model"] == models[it] } : []
          new(mode:, author:, avoid:, label:)
        end

        # Whether it keeps the unit off avoid: a mode other than any, for
        # a rewrite whose author was recorded.
        def active? = mode != "any" && !author.nil?

        def required? = active? && mode == "require_different"

        # The pairing's outcome for a unit that ran on name, for the
        # provenance record: met, not_met, not_applicable (mode any), or
        # unchecked (no author recorded).
        def outcome(name)
          return "not_applicable" if mode == "any"
          return "unchecked" unless author

          avoid.include?(name) ? "not_met" : "met"
        end

        # The providers of order, a unit's, that it may try, in order: the
        # author's last, for prefer_different, so they're used only when
        # nothing else is left, and not at all for require_different.
        def order(order)
          return order unless active?

          others, authors = order.partition { !avoid.include?(it) }
          required? ? others : others + authors
        end

        # require_different's failure when step's unit has no provider left
        # but the rewrite's author, with each provider tried, by name, and
        # its Error.
        def failure(step, tried)
          list = tried.map { |name, error| "#{name} (#{error.rule})" }.join(", ")
          Error.new("llm_unavailable", "#{step}: #{label || "the rewrite"} was written by #{author["name"]}, and " \
                                       "counterexample_pairing is require_different, but no provider it may use is " \
                                       "left that didn't write it or share its model#{": #{list}" unless tried.empty?}")
        end
      end
    end
  end
end
