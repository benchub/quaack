# frozen_string_literal: true

module Quaack
  module Driver
    class Provenance
      # The record's counterexample_rounds (task 20261111-191130-1): each
      # rewrite's tries at its counterexample rounds, each by round number,
      # "1" to "3", with the round's inserts as the LLM wrote them, the
      # entry that wrote them, and the driver's feedback on them, so a
      # round can be replayed by hand.
      #
      #   { "rewrite_3" => [{ "1" => { "entry" => "groq", "inserts" => ["INSERT ..."], "feedback" => "..." } }] }
      module Rounds
        # The round numbers, as keys, from 1 to the most a rewrite gets.
        NUMBERS = (1..Shape::MOST_ROUNDS).map(&:to_s).freeze
        KEYS = %w[entry inserts feedback].freeze

        # Round number of rewrite's counterexamples: its inserts, and the
        # entry that wrote them, or its feedback, once compare has loaded
        # them. Round 1's inserts start a new try after those recorded
        # before, so a resumed run that reruns the rewrite's rounds keeps
        # the earlier ones as first recorded.
        def counterexample_round!(rewrite, round, inserts: nil, entry: nil, feedback: nil)
          return self unless REWRITE.match?(rewrite) && NUMBERS.include?(round.to_s)

          tries = (@record["counterexample_rounds"] ||= {})[rewrite] ||= []
          inserts!(tries, round, inserts, entry) if Rounds.inserts?(inserts)
          feedback!(tries, round, feedback)
          self
        end

        # raw as the record keeps it: each rewrite's tries, each with only
        # its well-formed rounds, and none left empty. nil if it isn't a
        # Hash.
        def self.check(raw)
          return unless raw.is_a?(Hash)

          kept = raw.select { |rewrite, tries| REWRITE.match?(rewrite) && tries.is_a?(Array) }
          kept.transform_values { |tries| tries.filter_map { try(it) } }.reject { |_, tries| tries.empty? }
        end

        # A try's well-formed rounds, or nil if it has none.
        def self.try(raw)
          kept = raw.select { |number, round| NUMBERS.include?(number) && round?(round) } if raw.is_a?(Hash)
          kept unless kept.nil? || kept.empty?
        end

        # Whether raw is a round: its inserts and, if given, its entry, a
        # name, and its feedback, a String. No other key.
        def self.round?(raw)
          return false unless raw.is_a?(Hash) && (raw.keys - KEYS).empty? && inserts?(raw["inserts"])

          (!raw.key?("entry") || NAME.match?(raw["entry"].to_s)) &&
            (!raw.key?("feedback") || raw["feedback"].is_a?(String))
        end

        def self.inserts?(inserts) = inserts.is_a?(Array) && inserts.all?(String)

        private

        def inserts!(tries, round, inserts, entry)
          tries << {} if round == 1 || tries.empty?
          tries.last[round.to_s] = { "entry" => (entry if named?(entry)), "inserts" => inserts }.compact
        end

        # Adds feedback, if it's a String, to the latest try's round.
        def feedback!(tries, round, feedback)
          tries.last&.dig(round.to_s)&.store("feedback", feedback) if feedback.is_a?(String)
        end
      end
    end
  end
end
