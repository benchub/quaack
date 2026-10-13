# frozen_string_literal: true

require "quaack/protocol/fuzz_result"
require_relative "../deadline"
require_relative "enumerate/limit"
require_relative "enumerate/kinds"
require_relative "enumerate/worlds"

module Quaack
  module Enclave
    module Fuzz
      # rewrite-test's enumerate stage (task 20261012-3, DESIGN.md's
      # rewrite-test): after the fuzz search passes, every small world over
      # each table's row kinds (Kinds), in order of weight (Worlds), in the
      # fuzz search's own session, until its Limit or the rewrite's
      # Deadline. A kill is shrunk and lifted as the search's are (Fuzz's
      # Search#confirm), and only a lifted one disproves; one that doesn't
      # lift is dropped and enumeration goes on, up to Fuzz::LIFTS of them.
      #
      # verdict is :disproved, :passed (no lifted kill, a world compared,
      # and every world of at least one row tried), or :untested (it didn't
      # run, compared no world, or finished no bound). worlds counts the
      # worlds compared. bound is the most rows of every world tried
      # (Worlds#bound), 0 to Protocol::FuzzResult::MAX_BOUND, when it
      # passed or disproved, and nil when it's untested, so an enumeration
      # that compared nothing never claims one. sizes are a disproof's rows
      # per table, as the search's are. The worlds, kinds and values never
      # leave here.
      module Enumerate
        Outcome = Data.define(:verdict, :rule, :worlds, :bound, :sizes)

        def self.untested = Outcome.new(verdict: :untested, rule: nil, worlds: 0, bound: nil, sizes: [])

        # One enumeration, over a Fuzz search that passed.
        class Run
          def initialize(search, worlds, limit)
            @search = search
            @worlds = worlds
            @limit = limit
            @tried = 0
            @compared = 0
            @lifts = 0
            @done = -1
          end

          def call
            started = @limit.start
            catch(:stop) { weigh(started) }
            @outcome || ended
          rescue Deadline::Expired
            ended
          end

          private

          # Each weight's worlds in turn, noting each weight it finishes.
          def weigh(started)
            (0..@worlds.max_weight).each do |weight|
              @worlds.each(weight) { step(it, started) }
              @done = weight
            end
          end

          def step(rows, started)
            throw :stop if @lifts >= LIFTS || @limit.over?(@tried, started)
            Deadline.check!
            return unless killed?(rows)

            @lifts += 1
            rule, sizes = @search.confirm(rows)
            return unless rule

            @outcome = outcome(:disproved, rule, sizes)
            throw :stop
          end

          def killed?(rows)
            @tried += 1
            trial = @search.trial(rows)
            @compared += 1 if trial.compared
            trial.kill?
          end

          def ended
            bound = @worlds.bound(@done)
            outcome(@compared.positive? && bound.positive? ? :passed : :untested)
          end

          def outcome(verdict, rule = nil, sizes = [])
            bound = @worlds.bound(@done) unless verdict == :untested
            Outcome.new(verdict:, rule:, worlds: @compared, bound:, sizes:)
          end
        end
      end
    end
  end
end
