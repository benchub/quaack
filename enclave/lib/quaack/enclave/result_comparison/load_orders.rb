# frozen_string_literal: true

require_relative "../arena_fixture"

module Quaack
  module Enclave
    module ResultComparison
      # The load orders compare_in_both_orders runs, in the order it runs
      # them.
      LOAD_ORDERS = %i[forward reverse].freeze

      module_function

      # Step 9d's entry point, for step 9 orchestration (task 20260922-49)
      # to call. It runs the whole comparison (compare) twice, each time in
      # its own ArenaRunner transaction that rolls back: first with the
      # fixture loaded as given, then with it loaded in reverse.
      #
      # Why. Fixture rows load in id order, and a small sort keeps its input
      # order for ties. So a candidate that drops a sort key below the top
      # level, such as ORDER BY grp, id LIMIT 2 in a subquery or a LATERAL
      # top-1, gets the original's rows by luck. So does a DISTINCT or GROUP
      # BY that keeps a different representative of values Postgres calls
      # equal, such as '1 day' for '24 hours', or 'a' for 'A' under a
      # nondeterministic collation. A fresh load in reverse gives the heap
      # the reverse order, so a seq scan feeds those rows the other way
      # round, and the luck runs out.
      #
      # Both runs turn index scans off (ArenaRunner's index_scans: false).
      # Arena has the production indexes and no statistics, so the planner
      # reaches for them, and an index on (grp, id) hands back the grp ties
      # in id order whatever order the heap holds them in. 9d compares only
      # results, so the plan doesn't matter.
      #
      # rows are FixtureRows and inserts are raw INSERT statements, as
      # ArenaRunner#with_fixture takes them. The reverse load reverses the
      # rows within each run of consecutive rows for one table, and keeps
      # the runs, and so every pair of rows from different tables, in their
      # order. That keeps each parent before the child rows that reference
      # it, as the fixture must (ArenaRunner::FixtureRow). It can't do the
      # same for a table whose foreign key references itself: a child row
      # that comes after its parent in the same run comes before it in
      # reverse, and the load fails. A row that fails to load in the reverse
      # run raises reverse_load_failed, not fixture_load_failed, with index
      # its position in rows as given. The inserts always load in their own
      # order, after the rows. One INSERT can hold many rows, and reordering
      # them would mean rewriting it.
      #
      # It's a match only if both runs match. Otherwise it's the first run's
      # verdict that isn't a match, with load_order set to that run's load
      # order. That includes an unsupported_order refusal: if either run
      # refuses, the whole comparison does, and the reverse run doesn't run
      # after a forward mismatch.
      def compare_in_both_orders(runner, rows, original:, candidate:, inserts: [])
        positions = reverse_positions(rows)
        verdict = nil
        LOAD_ORDERS.zip([rows, positions.map { |i| rows[i] }]).each do |load_order, loaded|
          verdict = load_order_run(runner, loaded, inserts, load_order == :reverse ? positions : nil) do |tx|
            compare(tx, original:, candidate:)
          end
          return verdict.with(load_order:) unless verdict.match?
        end
        verdict
      end

      # rows with each run of consecutive rows for one table reversed.
      def reverse_load(rows) = reverse_positions(rows).map { |i| rows[i] }

      # The positions in rows, in reverse load order.
      def reverse_positions(rows)
        rows.each_index.chunk_while { |i, j| rows[i].table == rows[j].table }.flat_map(&:reverse)
      end

      # One run. For the reverse run, positions maps a row's place in the
      # reversed list back to its place in rows.
      def load_order_run(runner, loaded, inserts, positions, &)
        runner.with_fixture(loaded, inserts:, index_scans: false, &)
      rescue ArenaRunner::Error => e
        raise unless positions && e.rule == :fixture_load_failed

        raise ArenaRunner::Error.new(:reverse_load_failed, step: e.step, sqlstate: e.sqlstate,
                                                           index: positions.fetch(e.index)), cause: nil
      end
    end
  end
end
