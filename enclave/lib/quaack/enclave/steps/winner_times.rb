# frozen_string_literal: true

require "quaack/protocol/winner_timing"

module Quaack
  module Enclave
    module Steps
      # The winner's times, for ReportPayload (DESIGN.md's winner-timing and
      # report). winner-timing ran the winner once with timing on, apart
      # from the measured runs. When that run's plan has the same steps as
      # the winner's measured plan, in the same order, each step's
      # actual_total_time and actual_loops come from it; every other field,
      # the block counts and row counts with them, stays the measured
      # plan's, the ones that ranked it.
      #
      #   WinnerTimes.call(store, selection, labels, nodes)
      #   # => [labels, winner_timing]
      #
      # labels are ReportPayload's, each with its "plan" as nodes; nodes
      # turns a stored plan into them. winner_timing is one of
      # Protocol::WinnerTiming::RESULTS: timed when the times went in,
      # plan_differs when the steps differ, or the run's timed_out or
      # failed. It's nil with no winner, with no winner_timing entry (a run
      # from before winner-timing), with one for another label, with no
      # measured plan to put times in, or with a result that isn't one of
      # QUAACK's own.
      #
      # Trust boundary. Only numbers from the timed plan go out, each one
      # ReportPayload's timing passed as a finite number of zero or more,
      # and a word from the fixed list.
      module WinnerTimes
        # What makes two steps the same step.
        SHAPE = %w[node relation index depth].freeze
        TIMING = %w[actual_total_time actual_loops].freeze

        module_function

        def call(store, selection, labels, nodes)
          winner = selection["top"].first&.fetch("label")
          entry = entry(store, winner)
          index = labels.index { it["label"] == winner && it["plan"] }
          return [labels, nil] unless entry && index

          plan, result = timed(labels[index]["plan"], entry, nodes)
          [labels.each_with_index.map { |label, i| i == index ? label.merge("plan" => plan) : label }, result]
        end

        # The winner_timing entry, if it's the winner's.
        def entry(store, winner)
          return unless winner && store.entry?("winner_timing")

          store.read("winner_timing").then { it if it["label"] == winner }
        end

        # The measured plan with the timed run's times, if they went in,
        # and the result.
        def timed(measured, entry, nodes)
          result = entry["result"]
          return [measured, (result if Protocol::WinnerTiming.valid?(result))] unless result == "timed"

          return [measured, nil] unless entry["plan"]

          steps = nodes.call(entry["plan"])
          return [measured, "plan_differs"] unless same?(measured, steps)

          [measured.zip(steps).map { |step, run| step.merge(run.slice(*TIMING)) }, "timed"]
        end

        def same?(measured, steps) = measured.map { it.slice(*SHAPE) } == steps.map { it.slice(*SHAPE) }
      end
    end
  end
end
