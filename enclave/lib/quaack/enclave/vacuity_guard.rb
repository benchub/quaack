# frozen_string_literal: true

require "quaack/protocol/vacuity_diagnostic"
require_relative "arena_runner"
require_relative "deparse"
require_relative "predicate_atoms"
require_relative "result_comparison"
require_relative "scenarios"

module Quaack
  module Enclave
    # vacuity-guard: checks that S1 exercises every atom.
    #
    #   builder = Scenarios::Builder.new(arena_connection, PgQuery.parse(sql))
    #   result = VacuityGuard.run(ArenaRunner.new(arena_connection), builder, sql)
    #   result.untested   # => ["o.kind = $1"], redacted shapes, for the driver
    #   result.scenarios  # => the scenarios built with the final variants, for fixture-compare
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
    # the untested atoms' indexes, for counterexamples, and untested_paths
    # their paths into the original's parse, for AtomPosition.
    #
    # Trust boundary: untested holds only the atoms' shapes, which have every
    # literal redacted. scenarios hold real values and stay in the enclave.
    module VacuityGuard
      RETRIES = 3

      Result = Data.define(:untested, :untested_atoms, :untested_paths, :retries, :variants, :scenarios, :s1_load_rule,
                           :s1_rows) do
        def inspect = "#<data #{self.class} untested=#{untested} retries=#{retries} scenarios=<redacted>>"

        alias_method :to_s, :inspect
      end

      module_function

      def run(runner, builder, sql)
        loosened, unreplaceable = loosened_queries(builder)
        state = { exercised: [], variants: {}, retries: 0, s1_load_rule: nil, s1_rows: nil }
        (0..RETRIES).each do |attempt|
          scenarios = builder.build(state[:variants])
          fixtures = [scenarios[:s1], *builder.spills.fetch(:s1, [])]
          vacuous = vacuous_atoms(runner, fixtures, sql, loosened, state)
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
                   untested_paths: untested.map { |i| builder.atoms[i].path },
                   retries: state[:retries], variants: state[:variants], scenarios:,
                   s1_load_rule: state[:s1_load_rule], s1_rows: state[:s1_rows])
      end

      # The atoms not yet exercised that none of S1's fixtures exercise
      # either: its first, and its further ones (Scenarios::Parts), which
      # fixture-compare runs too. A fixture that won't load (a trigger or
      # constraint QUAACK doesn't model, say) exercises nothing, so its
      # atoms stay vacuous, are retried, and end untested. Scenarios never
      # crash rewrite-test. The S1 diagnostic is the first fixture's.
      def vacuous_atoms(runner, fixtures, sql, loosened, state)
        pending = loosened.keys - state[:exercised]
        first, *rest = fixtures
        state[:exercised] += loaded_exercised_atoms(runner, first, sql, loosened.slice(*pending), state)
        rest.each do |rows|
          state[:exercised] += spill_exercised_atoms(runner, rows, sql, loosened, pending - state[:exercised])
        end
        pending - state[:exercised]
      end

      def spill_exercised_atoms(runner, rows, sql, loosened, left)
        left.empty? ? [] : exercised_atoms(runner, rows, sql, loosened.slice(*left))
      rescue ArenaRunner::Error => e
        raise unless LOAD_STEPS.include?(e.step)

        []
      end

      LOAD_STEPS = %i[load insert].freeze

      # state also takes the last attempt's S1 diagnostic: the rule the load
      # failed with, or the original's row count once it loaded.
      def loaded_exercised_atoms(runner, rows, sql, loosened, state)
        state[:s1_load_rule] = nil
        exercised_atoms(runner, rows, sql, loosened) { state[:s1_rows] = it }
      rescue ArenaRunner::Error => e
        raise unless LOAD_STEPS.include?(e.step)

        state[:s1_load_rule] = load_rule(e.rule)
        state[:s1_rows] = nil
        []
      end

      # The rule a load failed with if it's on the fixed list, else :other.
      def load_rule(rule)
        Protocol::VacuityDiagnostic::LOAD_RULES.include?(rule.to_s) ? rule : :other
      end

      # Each replaceable atom's loosened query, and the atoms that can't be
      # replaced.
      def loosened_queries(builder)
        loosened = {}
        unreplaceable = []
        builder.atoms.each_with_index do |atom, i|
          loosened[i] = PredicateAtoms.with_true(builder.parse, atom)
        rescue PredicateAtoms::Error, Deparse::Error
          unreplaceable << i
        end
        [loosened, unreplaceable]
      end

      # The atoms, of those loosened maps to their loosened queries, whose
      # loosened query changes the original's result on this fixture. counterexample-compare
      # reuses it on its counterexamples.
      #
      # When the original's top level has a LIMIT or an OFFSET, equal rows
      # can still hide a changed result: an unordered LIMIT 1 returns the
      # hit whichever row the loosened query lets through, and a cut tie
      # group can do the same. So an atom equal rows leave vacuous there is
      # exercised if fixture-compare (ResultComparison.compare_in_load_orders,
      # every load order) finds the loosened query a mismatch: just what
      # would catch a rewrite that dropped it. A refusal compares nothing,
      # so it isn't one, and nor is a comparison that fails to run (a
      # reordered load that won't load, say).
      def exercised_atoms(runner, rows, sql, loosened, inserts: [], &)
        changed = changed_atoms(runner, rows, sql, loosened, inserts, &)
        return changed unless top_level_cut?(sql)

        changed + loosened.except(*changed).select { |_, query| mismatch?(runner, rows, sql, query, inserts) }.keys
      end

      # The atoms whose loosened query returns other rows.
      def changed_atoms(runner, rows, sql, loosened, inserts)
        runner.with_fixture(rows, inserts:) do |tx|
          result = tx.query(sql)
          yield result.rows.size if block_given?
          base = multiset(result)
          loosened.reject { |_, query| multiset(tx.query(query)) == base }.keys
        end
      end

      def top_level_cut?(sql)
        select = PgQuery.parse(sql).tree.stmts.first&.stmt&.select_stmt
        !!(select && (select.limit_count || select.limit_offset))
      end

      def mismatch?(runner, rows, sql, query, inserts)
        verdict = ResultComparison.compare_in_load_orders(runner, rows, original: sql, candidate: query, inserts:)
        ResultComparator::MISMATCHES.include?(verdict.rule)
      rescue ArenaRunner::Error
        false
      end

      def multiset(result) = result.rows.map { |row| row.map { |v| v.nil? ? [0, ""] : [1, v] } }.sort
    end
  end
end
