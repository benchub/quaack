# frozen_string_literal: true

require_relative "../arena_runner"
require_relative "search/skips"
require_relative "search/trials"

module Quaack
  module Enclave
    module VacuityGuard
      # vacuity-guard's search (20261010-43): for the atoms the rule-based
      # scenarios leave untested, a bounded random search for a tiny
      # database on which the query and its loosened query (the atom
      # replaced by TRUE) return different results.
      #
      #   outcome = Search.new(runner, schema, order, sql, value_rows, pools).run(loosened)
      #   outcome.fixtures  # => the trials that told an atom apart, for rewrite-test to replay
      #   outcome.found     # => the atoms they closed
      #   outcome.states    # => { atom => :searched or :not_searched }, for the rest
      #
      # The trials come from Trials: one row a table for the first SIZES
      # share of the budget, then up to two, then up to MAX_ROWS. Each loads
      # in its own arena transaction that rolls back (ArenaRunner#with_fixture),
      # and is tested with the guard's own test (VacuityGuard.exercised_atoms).
      # A trial that won't load or whose query fails (a constraint, a scalar
      # subquery with two rows, the statement timeout) is discarded: it
      # tests nothing, and still counts against the budget.
      #
      # The budget is TRIALS_PER_ATOM trials for each atom searched, and
      # SECONDS in all. An atom left when the trials run out was searched
      # with no difference found; one left when the clock or the cap on kept
      # trials (MAX_FIXTURES) stops the search wasn't searched in full.
      # Neither ever counts an atom tested. A kept trial closed an atom no
      # earlier one did. A query Skips names isn't searched. The generator is
      # seeded with SEED, so a run is reproducible.
      #
      # Trust boundary: the trial rows hold made-up values (and the query's
      # literals, through the pools) and stay in the enclave. Only the atoms
      # closed and their state words leave.
      class Search
        TRIALS_PER_ATOM = 150
        SECONDS = 5
        MAX_FIXTURES = 3
        SEED = 20_261_010
        MAX_ROWS = 4
        SIZES = [[0.1, 1], [0.4, 2]].freeze

        Outcome = Data.define(:fixtures, :found, :states, :trials, :discarded) do
          def inspect = "#<data #{self.class} found=#{found} states=#{states} fixtures=<redacted>>"

          alias_method :to_s, :inspect
        end

        # The search's verdict on the atoms vacuous maps to their loosened
        # queries, by atom: :tested, :searched or :not_searched. The trials
        # that told an atom apart join S1's further fixtures, so rewrite-test
        # replays them for every candidate. Its trials aren't counted as
        # loads: how many it ran follows the data, and through it the query's
        # literals.
        # options is nil when the guard runs without the search, or the
        # keywords for Search.new.
        def self.close(runner, builder, sql, vacuous, scenarios, options) # rubocop:disable Metrics/ParameterLists
          return {} if vacuous.empty? || options.nil?

          outcome = runner.uncounted { searcher(runner, builder, sql, scenarios, options).run(vacuous) }
          builder.add_spills(:s1, outcome.fixtures)
          outcome.states.merge(outcome.found.to_h { [it, :tested] })
        end

        def self.searcher(runner, builder, sql, scenarios, options)
          rows = [*scenarios.values, *builder.spills.values.flatten(1)].flatten
          new(runner, builder.schema, builder.topology.order, sql, rows, builder.pools, **options)
        end

        # The atoms of untested that states doesn't say the search told apart.
        def self.left(untested, states) = untested.reject { states[it] == :tested }.sort

        # rubocop:disable Metrics/ParameterLists
        def initialize(runner, schema, order, sql, value_rows, pools, trials_per_atom: TRIALS_PER_ATOM,
                       seconds: SECONDS, seed: SEED, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          # rubocop:enable Metrics/ParameterLists
          @runner = runner
          @sql = sql
          @trials = Trials.new(schema, order, value_rows, pools, Random.new(seed))
          @trials_per_atom = trials_per_atom
          @seconds = seconds
          @clock = clock
        end

        def run(loosened)
          return outcome([], loosened.keys, :not_searched, 0, 0) if loosened.empty? || Skips.skip?(@sql)

          search(loosened, @trials_per_atom * loosened.size)
        end

        private

        def outcome(kept, left, state, trials, discarded)
          Outcome.new(fixtures: kept.map(&:first), found: kept.flat_map(&:last),
                      states: left.to_h { [it, state] }, trials:, discarded:)
        end

        def search(left, budget)
          run = { left:, kept: [], trials: 0, discarded: 0, started: @clock.call,
                  compared: Compared.new(MAX_COMPARISONS) }
          trial(run, budget) while going?(run, budget)
          state = run[:trials] >= budget ? :searched : :not_searched
          outcome(run[:kept], run[:left].keys, state, run[:trials], run[:discarded])
        end

        def trial(run, budget)
          rows = @trials.make(size(run[:trials], budget))
          run[:trials] += 1
          hit = test(rows, run[:left], run[:compared])
          return run[:discarded] += 1 if hit.nil?
          return if hit.empty?

          run[:kept] << [rows, hit]
          run[:left] = run[:left].except(*hit)
        end

        def going?(run, budget)
          run[:left].any? && run[:trials] < budget && run[:kept].size < MAX_FIXTURES &&
            @clock.call - run[:started] < @seconds
        end

        # The atoms the trial tells apart, or nil when it's discarded.
        def test(rows, left, compared)
          VacuityGuard.exercised_atoms(@runner, rows, @sql, left, compared:)
        rescue ArenaRunner::Error => e
          raise if ArenaRunner::Cancel.foreign?(e)

          nil
        end

        def size(trials, budget) = SIZES.find { |share, _| trials < share * budget }&.last || MAX_ROWS
      end
    end
  end
end
