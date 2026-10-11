# frozen_string_literal: true

require "quaack/protocol/vacuity_diagnostic"
require_relative "arena_runner"
require_relative "deparse"
require_relative "predicate_atoms"
require_relative "result_comparison"
require_relative "scenarios"
require_relative "vacuity_guard/compared"

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

      # The most fixture-compare runs one guard run makes (Compared).
      # Past it, an atom equal rows leave vacuous stays vacuous, so it's
      # retried and ends untested: the cap never counts an atom tested.
      MAX_COMPARISONS = 32

      Result = Data.define(:untested, :untested_atoms, :untested_paths, :retries, :variants, :scenarios, :s1_load_rule,
                           :s1_rows, :s1_nonzero_rows) do
        def inspect = "#<data #{self.class} untested=#{untested} retries=#{retries} scenarios=<redacted>>"

        alias_method :to_s, :inspect
      end

      module_function

      def run(runner, builder, sql)
        loosened, unreplaceable = loosened_queries(builder)
        state = new_state
        (0..RETRIES).each do |attempt|
          scenarios = builder.build(state[:variants])
          vacuous = vacuous_atoms(runner, s1_fixtures(builder, scenarios), sql, loosened, state)
          done = vacuous.empty? || attempt == RETRIES
          return result(builder, (vacuous + unreplaceable).sort, state, scenarios) if done

          retry_atoms(state, vacuous, attempt + 1)
        end
      end

      def s1_fixtures(builder, scenarios) = [scenarios[:s1], *builder.spills.fetch(:s1, [])]

      def new_state
        { exercised: [], variants: {}, retries: 0, s1_load_rule: nil, s1_rows: nil, s1_nonzero_rows: nil,
          compared: Compared.new(MAX_COMPARISONS) }
      end

      def retry_atoms(state, vacuous, step)
        state[:retries] += vacuous.size
        vacuous.each { |i| state[:variants][i] = step }
      end

      def result(builder, untested, state, scenarios)
        Result.new(untested: untested.map { |i| builder.atoms[i].shape }, untested_atoms: untested,
                   untested_paths: untested.map { |i| builder.atoms[i].path },
                   retries: state[:retries], variants: state[:variants], scenarios:,
                   s1_load_rule: state[:s1_load_rule], s1_rows: state[:s1_rows],
                   s1_nonzero_rows: state[:s1_nonzero_rows])
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
          left = loosened.slice(*(pending - state[:exercised]))
          state[:exercised] += spill_exercised_atoms(runner, rows, sql, left, state)
        end
        pending - state[:exercised]
      end

      def spill_exercised_atoms(runner, rows, sql, loosened, state)
        loosened.empty? ? [] : exercised_atoms(runner, rows, sql, loosened, compared: state[:compared])
      rescue ArenaRunner::Error => e
        raise unless LOAD_STEPS.include?(e.step)

        []
      end

      LOAD_STEPS = %i[load insert].freeze

      # state also takes the last attempt's S1 diagnostic: the rule the load
      # failed with, or the original's row count once it loaded, and how
      # many of those rows are nonzero (nonzero_rows).
      def loaded_exercised_atoms(runner, rows, sql, loosened, state)
        state[:s1_load_rule] = nil
        exercised_atoms(runner, rows, sql, loosened, compared: state[:compared]) { s1_counts(state, it) }
      rescue ArenaRunner::Error => e
        raise unless LOAD_STEPS.include?(e.step)

        state[:s1_load_rule] = load_rule(e.rule)
        s1_counts(state, nil)
        []
      end

      # The S1 row counts of result, the original's rows, or nil for both,
      # each 0 or REPORTED_ROWS, for one or more. S1's rows can follow the
      # query's literals (a LIMIT, or which values a list's groups take), so
      # an exact count, or even "two or more", could carry one out of the
      # enclave. Whether S1 matched anything is the part the diagnostic
      # needs.
      def s1_counts(state, result)
        state[:s1_rows] = result && [result.size, REPORTED_ROWS].min
        state[:s1_nonzero_rows] = result && [nonzero_rows(result), REPORTED_ROWS].min
      end

      REPORTED_ROWS = 1

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
      #
      # When the original returns no rows here, its full result has no more
      # rows than the OFFSET (or there's nothing to cut), and a loosened
      # query that returns none either has no row a load order could move.
      # Row counts don't depend on load order, so no comparison can be a
      # mismatch, and none is run.
      #
      # compared is the guard run's Compared, which skips a comparison
      # already made with no mismatch and any past MAX_COMPARISONS.
      # counterexample-compare passes none, so it gets no cap.
      def exercised_atoms(runner, rows, sql, loosened, inserts: [], compared: Compared.new, &) # rubocop:disable Metrics/ParameterLists
        changed, empty = changed_atoms(runner, rows, sql, loosened, inserts, &)
        return changed if empty || !top_level_cut?(sql)

        vacuous = loosened.except(*changed)
        changed + vacuous.select { |_, query| compared.mismatch?(runner, rows, sql, query, inserts) }.keys
      end

      # The atoms whose loosened query returns other rows, and whether the
      # original returned none.
      def changed_atoms(runner, rows, sql, loosened, inserts)
        runner.with_fixture(rows, inserts:) do |tx|
          result = tx.query(sql)
          yield result.rows if block_given?
          base = multiset(result)
          [loosened.reject { |_, query| multiset(tx.query(query)) == base }.keys, base.empty?]
        end
      end

      # How many rows hold a value that's neither NULL nor a numeric zero.
      # An aggregate always returns a row, so S1 matching nothing shows as
      # 0 here: count(*) gives 0, sum() and max() give NULL. Only a count
      # leaves the enclave, never a value.
      def nonzero_rows(rows) = rows.count { |row| row.any? { !it.nil? && !ZERO.match?(it.to_s) } }

      ZERO = /\A[-+]?(0+(\.0*)?|\.0+)\z/

      def top_level_cut?(sql)
        select = PgQuery.parse(sql).tree.stmts.first&.stmt&.select_stmt
        !!(select && (select.limit_count || select.limit_offset))
      end

      def multiset(result) = result.rows.map { |row| row.map { |v| v.nil? ? [0, ""] : [1, v] } }.sort
    end
  end
end
