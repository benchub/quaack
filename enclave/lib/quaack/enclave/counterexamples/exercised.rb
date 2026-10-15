# frozen_string_literal: true

require "pg_query"
require_relative "../arena_runner"
require_relative "../result_comparator"
require_relative "../result_comparison"

module Quaack
  module Enclave
    module Counterexamples
      # Which untested atoms a counterexample round's fixture exercised
      # (Counterexamples.covered). It was vacuity-guard's, until task
      # 20261012-4 removed the guard.
      #
      #   Exercised.atoms(runner, rows, original, { 2 => loosened_sql }, inserts:)  # => [2]
      #
      # loosened maps each atom's index to the original with that atom
      # replaced by TRUE (PredicateAtoms.with_true). An atom is exercised
      # if its loosened query returns other rows than the original on the
      # fixture.
      #
      # When the original's top level has a LIMIT or an OFFSET, equal rows
      # can still hide a changed result: an unordered LIMIT 1 returns the
      # hit whichever row the loosened query lets through, and a cut tie
      # group can do the same. So an atom equal rows leave vacuous there is
      # exercised if fixture-compare (ResultComparison.compare_in_load_orders,
      # every load order) finds the loosened query a mismatch: just what
      # would catch a rewrite that dropped it. A refusal compares nothing,
      # so it isn't one, and nor is a comparison that fails to run (a
      # reordered load that won't load, say). Those comparisons' loads
      # aren't counted (ArenaRunner#uncounted): how many run follows the
      # LIMIT's value (20261010-47).
      #
      # When the original returns no rows here, its full result has no more
      # rows than the OFFSET (or there's nothing to cut), and a loosened
      # query that returns none either has no row a load order could move.
      # Row counts don't depend on load order, so no comparison can be a
      # mismatch, and none is run.
      #
      # The original runs first, so a query error's index names the query
      # that failed. When it's the original, by an error from the data (a
      # division by a column that's 0, say) or QUAACK's own
      # statement_timeout, this raises OriginalFailed. When it's a loosened
      # query, its atom isn't counted exercised, and the fixture loads again
      # for the rest, uncounted, since whether a loosened query fails
      # follows the data. A cancel QUAACK didn't send goes up as it is.
      module Exercised
        # The original query failed on the fixture, by an error from the
        # data or QUAACK's own statement_timeout. Like a fixture that won't
        # load, the fixture then exercises nothing.
        class OriginalFailed < ArenaRunner::Error; end

        module_function

        def atoms(runner, rows, sql, loosened, inserts: [])
          changed, empty = changed_atoms(runner, rows, sql, loosened, inserts)
          return changed if empty || !top_level_cut?(sql)

          vacuous = loosened.except(*changed)
          changed + vacuous.select { |_, query| mismatch?(runner, rows, sql, query, inserts) }.keys
        end

        # The atoms whose loosened query returns other rows, and whether the
        # original returned none.
        def changed_atoms(runner, rows, sql, loosened, inserts)
          failed = []
          begin
            left = loosened.except(*failed)
            run = -> { changed_on(runner, rows, sql, left, inserts) }
            changed, empty = failed.empty? ? run.call : runner.uncounted(&run)
          rescue ArenaRunner::Error => e
            failed << failed_atom(e, left)
            retry
          end
          [changed, empty]
        end

        # The atom of left whose loosened query failed with error, or else
        # error goes up: as OriginalFailed when the original failed.
        def failed_atom(error, left)
          raise error if ArenaRunner::Cancel.foreign?(error) || error.step != :query || error.index.nil?
          if error.index.zero?
            raise OriginalFailed.new(error.rule, step: error.step, sqlstate: error.sqlstate, index: 0), cause: nil
          end

          left.keys.fetch(error.index - 1)
        end

        def changed_on(runner, rows, sql, loosened, inserts)
          runner.with_fixture(rows, inserts:) do |tx|
            base = multiset(tx.query(sql))
            [loosened.reject { |_, query| multiset(tx.query(query)) == base }.keys, base.empty?]
          end
        end

        def mismatch?(runner, rows, sql, query, inserts)
          verdict = runner.uncounted do
            ResultComparison.compare_in_load_orders(runner, rows, original: sql, candidate: query, inserts:)
          end
          ResultComparator::MISMATCHES.include?(verdict.rule)
        rescue ArenaRunner::Error
          false
        end

        def top_level_cut?(sql)
          select = PgQuery.parse(sql).tree.stmts.first&.stmt&.select_stmt
          !!(select && (select.limit_count || select.limit_offset))
        end

        def multiset(result) = result.rows.map { |row| row.map { |v| v.nil? ? [0, ""] : [1, v] } }.sort
      end
    end
  end
end
