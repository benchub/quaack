# frozen_string_literal: true

require_relative "arena_runner"
require_relative "deparse"
require_relative "predicate_atoms"
require_relative "scenarios"

module Quaack
  module Enclave
    # 9c: checks that S1 exercises every atom.
    #
    #   builder = Scenarios::Builder.new(arena_connection, PgQuery.parse(sql))
    #   result = VacuityGuard.run(ArenaRunner.new(arena_connection), builder, sql)
    #   result.untested   # => ["o.kind = $1"], redacted shapes, for the driver
    #   result.scenarios  # => the scenarios built with the final variants, for 9d
    #
    # In one arena transaction with S1 loaded, it runs the original, and the
    # original with each atom replaced by TRUE (PredicateAtoms.with_true).
    # An atom whose replacement returns the same multiset of rows is
    # vacuous. Each vacuous atom is retried, up to three times, with the
    # scenarios rebuilt with its pool lists rotated one step further
    # (Scenarios' variants). An atom exercised once stays exercised. One
    # still vacuous after three retries is untested. So is one with_true
    # can't replace (a USING column, or a deparse it can't trust), with no
    # retry.
    #
    # retries counts the rebuilds of each vacuous atom. untested_atoms are
    # the untested atoms' indexes, for step 10.
    #
    # Trust boundary: untested holds only the atoms' shapes, which have every
    # literal redacted. scenarios hold real values and stay in the enclave.
    module VacuityGuard
      RETRIES = 3

      Result = Data.define(:untested, :untested_atoms, :retries, :variants, :scenarios) do
        def inspect = "#<data #{self.class} untested=#{untested} retries=#{retries} scenarios=<redacted>>"

        alias_method :to_s, :inspect
      end

      module_function

      def run(runner, builder, sql)
        loosened, unreplaceable = loosened_queries(builder)
        state = { exercised: [], variants: {}, retries: 0 }
        (0..RETRIES).each do |attempt|
          scenarios = builder.build(state[:variants])
          vacuous = vacuous_atoms(runner, scenarios[:s1], sql, loosened, state)
          done = vacuous.empty? || attempt == RETRIES
          return result(builder, (vacuous + unreplaceable).sort, state, scenarios) if done

          retry_atoms(state, vacuous, attempt + 1)
        end
      end

      def retry_atoms(state, vacuous, step)
        state[:retries] += vacuous.size
        vacuous.each { |i| state[:variants][i] = step }
      end

      def result(builder, untested, state, scenarios)
        Result.new(untested: untested.map { |i| builder.atoms[i].shape }, untested_atoms: untested,
                   retries: state[:retries], variants: state[:variants], scenarios:)
      end

      # The atoms not yet exercised that this fixture doesn't exercise
      # either.
      def vacuous_atoms(runner, rows, sql, loosened, state)
        pending = loosened.keys - state[:exercised]
        state[:exercised] += exercised_atoms(runner, rows, sql, loosened.slice(*pending))
        pending - state[:exercised]
      end

      # Each replaceable atom's loosened query, and the atoms that can't be
      # replaced.
      def loosened_queries(builder)
        loosened = {}
        unreplaceable = []
        builder.atoms.each_with_index do |atom, i|
          loosened[i] = PredicateAtoms.with_true(builder.parse, atom)
        rescue ArgumentError, Deparse::Error
          unreplaceable << i
        end
        [loosened, unreplaceable]
      end

      def exercised_atoms(runner, rows, sql, loosened)
        runner.with_fixture(rows) do |tx|
          base = multiset(tx.query(sql))
          loosened.reject { |_, query| multiset(tx.query(query)) == base }.keys
        end
      end

      def multiset(result) = result.rows.map { |row| row.map { |v| v.nil? ? [0, ""] : [1, v] } }.sort
    end
  end
end
