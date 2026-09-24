# frozen_string_literal: true

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
      # rows are FixtureRows and inserts are raw INSERT statements, as
      # ArenaRunner#with_fixture takes them. The reverse load reverses the
      # rows within each run of consecutive rows for one table, and keeps
      # the runs, and so every pair of rows from different tables, in their
      # order. That keeps each parent before the child rows that reference
      # it, as the fixture must (ArenaRunner::FixtureRow). It can't do the
      # same for a table whose foreign key references itself: a child row
      # that comes after its parent in the same run comes before it in
      # reverse, and the load fails with fixture_load_failed. The inserts
      # always load in their own order, after the rows. One INSERT can hold
      # many rows, and reordering them would mean rewriting it.
      #
      # It's a match only if both runs match. Otherwise it's the first run's
      # verdict that isn't a match, with load_order set to that run's load
      # order. That includes an unsupported_order refusal: if either run
      # refuses, the whole comparison does, and the reverse run doesn't run
      # after a forward mismatch.
      def compare_in_both_orders(runner, rows, original:, candidate:, inserts: [])
        verdict = nil
        LOAD_ORDERS.zip([rows, reverse_load(rows)]).each do |load_order, loaded|
          verdict = runner.with_fixture(loaded, inserts:) { |tx| compare(tx, original:, candidate:) }
          return verdict.with(load_order:) unless verdict.match?
        end
        verdict
      end

      # rows with each run of consecutive rows for one table reversed.
      def reverse_load(rows) = rows.chunk_while { |a, b| a.table == b.table }.flat_map(&:reverse)
    end
  end
end
