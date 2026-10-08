# frozen_string_literal: true

require_relative "../arena_fixture"

module Quaack
  module Enclave
    module ResultComparison
      # The load orders compare_in_load_orders runs, in the order it runs
      # them.
      LOAD_ORDERS = %i[forward reverse rotated].freeze

      # The rule a row that fails to load raises in each load order but the
      # forward one, in place of fixture_load_failed.
      LOAD_FAILED = { reverse: :reverse_load_failed, rotated: :rotated_load_failed }.freeze

      module_function

      # fixture-compare's entry point, for rewrite-test and counterexamples.
      # It runs the whole comparison (compare) three times, each time in its
      # own ArenaRunner transaction that rolls back: first with the fixture
      # loaded as given, then in reverse, then rotated by one.
      #
      # Why. Fixture rows load in id order, and a small sort keeps its input
      # order for ties. So a candidate that drops a sort key below the top
      # level, such as ORDER BY grp, id LIMIT 2 in a subquery or a LATERAL
      # top-1, gets the original's rows by luck. So does a DISTINCT or GROUP
      # BY that keeps a different representative of values Postgres calls
      # equal, such as jsonb's {"a": 1.0} for {"a": 1.00}, or 'a' for 'A' under a
      # nondeterministic collation. A fresh load in reverse gives the heap
      # the reverse order, so a seq scan feeds those rows the other way
      # round, and the luck runs out. Reversing keeps the middle of an
      # odd-sized run in the middle, so a pick there (OFFSET 1 LIMIT 1 over
      # three ties) matches both ways. The rotated load moves each run's
      # first row to its end, which shifts the middle.
      #
      # All runs turn index scans off (ArenaRunner's index_scans: false).
      # Arena has the production indexes and no statistics, so the planner
      # reaches for them, and an index on (grp, id) hands back the grp ties
      # in id order whatever order the heap holds them in. fixture-compare compares only
      # results, so the plan doesn't matter.
      #
      # rows are FixtureRows and inserts are raw INSERT statements, as
      # ArenaRunner#with_fixture takes them. Each reordered load (reordered_load)
      # reorders the rows within each run of consecutive rows for one table,
      # and keeps the runs, and so every pair of rows from different tables,
      # in their order. That keeps each parent before the child rows that
      # reference it, as the fixture must (ArenaRunner::FixtureRow). A table
      # whose foreign key references itself is reordered level by level
      # (self_reference_levels). A row that fails to load in a reordered run raises that
      # order's LOAD_FAILED rule, not fixture_load_failed, with index its
      # position in rows as given. The inserts always load in their own
      # order, after the rows. One INSERT can hold many rows, and reordering
      # them would mean rewriting it.
      #
      # It's a match only if every run matches. Otherwise it's the first
      # run's verdict that isn't a match, with load_order set to that run's
      # load order. That includes an unsupported_order refusal: if any run
      # refuses, the whole comparison does, and later runs don't run.
      def compare_in_load_orders(runner, rows, original:, candidate:, inserts: [])
        verdict = nil
        LOAD_ORDERS.each do |load_order|
          positions = load_positions(rows, load_order, runner)
          verdict = load_order_run(runner, positions.map { rows[it] }, inserts, load_order, positions) do |tx|
            compare(tx, original:, candidate:)
          end
          return verdict.with(load_order:) unless verdict.match?
        end
        verdict
      end

      # rows reordered for load_order. runner reads the self-referencing
      # foreign keys (ArenaRunner#self_references); without one, every table
      # counts as having none.
      def reordered_load(rows, load_order, runner = nil) = load_positions(rows, load_order, runner).map { rows[it] }

      # rows with each run of consecutive rows for one table reversed.
      def reverse_load(rows) = reordered_load(rows, :reverse)

      # The positions in rows, in load_order: each run of consecutive rows
      # for one table split into levels, and each level reordered.
      def load_positions(rows, load_order, runner)
        return rows.each_index.to_a if load_order == :forward

        keys = runner ? runner.self_references(rows.map(&:table).uniq) : {}
        table_runs(rows).flat_map do |run|
          self_reference_levels(rows, run, keys.fetch(rows[run.first].table, [])).flat_map { reorder(it, load_order) }
        end
      end

      # The positions in rows, split into runs of consecutive rows for one
      # table.
      def table_runs(rows) = rows.each_index.chunk_while { |i, j| rows[i].table == rows[j].table }

      def reorder(level, load_order) = load_order == :reverse ? level.reverse : level.rotate

      # A run's positions, split by depth in the tree its self-referencing
      # foreign keys (keys, [columns, referenced columns] pairs) make: the
      # rows with no parent earlier in the run first, then their children,
      # and so on, each level in its order in the run. A parent is always on
      # a lower level than its child, so reordering within each level keeps
      # it first. A row finds its parent by text: the parent's referenced
      # columns hold the same strings as its foreign-key columns. One whose
      # parent's key is written another way ('01' for 1) sits at the top,
      # and its reordered load can fail.
      def self_reference_levels(rows, run, keys)
        return [run] if keys.empty?

        depths = self_reference_depths(rows, run, keys)
        run.group_by { depths[it] }.sort.map(&:last)
      end

      # Each of run's positions' depth: 0 for a row with no parent earlier
      # in the run, and otherwise one more than its deepest parent's.
      # owners maps each key's referenced values to the first row that
      # holds them.
      def self_reference_depths(rows, run, keys)
        owners = keys.map { [it, {}] }
        run.each_with_object({}) do |i, depths|
          depths[i] = self_reference_parents(rows[i], owners).map { depths[it] + 1 }.max || 0
          owners.each { |(_, referenced), owned| own_key(owned, fixture_key(rows[i], referenced), i) }
        end
      end

      def self_reference_parents(row, owners)
        owners.filter_map { |(columns, _), owned| owned[fixture_key(row, columns)] }
      end

      def own_key(owned, key, position)
        owned[key] ||= position if key
      end

      # row's values in columns, or nil if it leaves one out or it's NULL.
      def fixture_key(row, columns)
        values = columns.map { |c| (index = row.columns.index(c)) && row.values[index] }
        values unless values.any?(&:nil?)
      end

      # One run. For a reordered run, positions maps a row's place in the
      # reordered list back to its place in rows.
      def load_order_run(runner, loaded, inserts, load_order, positions, &)
        runner.with_fixture(loaded, inserts:, index_scans: false, &)
      rescue ArenaRunner::Error => e
        raise unless LOAD_FAILED.key?(load_order) && e.rule == :fixture_load_failed

        raise ArenaRunner::Error.new(LOAD_FAILED.fetch(load_order), step: e.step, sqlstate: e.sqlstate,
                                                                    index: positions.fetch(e.index)), cause: nil
      end
    end
  end
end
