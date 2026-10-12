# frozen_string_literal: true

require_relative "../arena_fixture"
require_relative "../arena_runner"
require_relative "../denormalized_fixture"
require_relative "../result_comparator"
require_relative "../result_comparison/load_orders"
require_relative "typical"

module Quaack
  module Enclave
    module Fuzz
      # Checks a counterexample the session found with every constraint
      # enforced, since the session dropped the foreign keys that leave the
      # footprint. Only a lifted counterexample disproves (DESIGN.md's
      # rewrite-test).
      #
      #   Lift.new(conn, catalog, domains, honour:, statement_timeout_ms:).call(rows, original:, candidate:)
      #   # => :row_count, or nil when it doesn't hold
      #
      # It builds a parent row for each reference a world row makes out of
      # the footprint, and for each such parent's own references, however
      # far up: the referenced values, a fresh value in each unique key's
      # columns, NULL in a nullable foreign key, and an ordinary value in
      # every other NOT NULL column without a default. A parent whose NOT
      # NULL key points back into the footprint can't be built, so the
      # counterexample doesn't lift. Then the parents, the deepest first,
      # and the world load in a fresh ArenaRunner transaction (honouring
      # the copies, as DenormalizedFixture::Runner does) with every
      # constraint checked, and ResultComparison.compare_in_load_orders
      # compares again. A load or query failure isn't a disproof; a cancel
      # that wasn't QUAACK's statement_timeout ends the step, as in
      # ScenarioTests.
      class Lift
        DEPTH = 20
        # Past the generator's fresh values, so a built key never meets a world's.
        FRESH = 500_000

        class Unliftable < StandardError
          def initialize(message = "the counterexample's parent rows can't be built") = super
        end

        def initialize(conn, catalog, domains, honour:, statement_timeout_ms:)
          @catalog = catalog
          @domains = domains
          @runner = DenormalizedFixture::Runner.new(conn, honour, statement_timeout_ms:)
          @fresh = FRESH
        end

        def call(rows, original:, candidate:)
          fixture = loaded(parents(rows)) + rows.map { fixture_row(it.table, it.cells) }
          verdict = ResultComparison.compare_in_load_orders(@runner, fixture, original:, candidate:)
          verdict.rule if !verdict.match? && ResultComparator::MISMATCHES.include?(verdict.rule)
        rescue Unliftable
          nil
        rescue ArenaRunner::Error => e
          raise if ArenaRunner::Cancel.foreign?(e)
        end

        private

        # The built parents in load order: by table, each table after the
        # tables its rows reference, and in a table, each row after the rows
        # built for it, which are its parents. A cycle among them loads in
        # the order found, and fails to load if it must.
        def loaded(built)
          by_table = built.group_by(&:table)
          table_order(by_table).flat_map { by_table.fetch(it).reverse }
        end

        def table_order(by_table)
          tables = by_table.keys
          order = []
          until tables.empty?
            ready = tables.find { |t| !referenced(t, by_table.fetch(t)).intersect?(tables) }
            order << tables.delete(ready || tables.first)
          end
          order
        end

        # The other tables rows reference, through a foreign key none of
        # whose columns they leave NULL.
        def referenced(table, rows)
          @catalog.foreign_keys(table).filter_map do |reference|
            next if reference.parent == table

            reference.parent if rows.any? { tuple(reference, it.columns.zip(it.values).to_h) }
          end
        end

        # Every world row is known before any parent is built, so a world
        # row a reference finds is never built again.
        def parents(rows)
          built = []
          have = Hash.new { |h, k| h[k] = [] }
          rows.each { have[it.table] << it.cells }
          rows.each { satisfy(it.table, it.cells, have, built, 0) } # rubocop:disable Style/CombinableLoops
          built
        end

        def satisfy(table, cells, have, built, depth)
          raise Unliftable if depth > DEPTH

          @catalog.foreign_keys(table).each do |reference|
            tuple = missing(table, reference, cells, have)
            next unless tuple

            parent = build(reference.parent, tuple, have)
            have[reference.parent] << parent
            built << fixture_row(reference.parent, parent)
            satisfy(reference.parent, parent, have, built, depth + 1)
          end
        end

        # The parent key a row references that no row has, or nil. Raises
        # Unliftable when that parent is a footprint table, whose rows are
        # the world.
        def missing(table, reference, cells, have)
          return if inside?(table) && inside?(reference.parent)

          tuple = tuple(reference, cells)
          return if tuple.nil? || have[reference.parent].any? { tuple <= it }
          raise Unliftable if inside?(reference.parent)

          tuple
        end

        def inside?(table) = @catalog.footprint.include?(table)

        # The parent columns and values a row references, or nil when any
        # is NULL.
        def tuple(reference, cells)
          key = reference.columns.map { cells[it] }
          reference.parent_columns.zip(key).to_h unless key.any?(&:nil?)
        end

        # A parent row of table holding tuple, its other columns as
        # Lift's comment says.
        def build(table, tuple, have)
          cells = tuple.dup
          foreign = @catalog.foreign_keys(table)
          @catalog.columns(table).each do |col|
            next if cells.key?(col.name) || col.default == "generated"

            link = foreign.find { it.columns.include?(col.name) }
            link ? reference(table, link, cells, have) : fill(table, col, cells)
          end
          cells
        end

        def fill(table, col, cells)
          if fresh?(table, col) then cells[col.name] = fresh_value(table, col.name)
          elsif !col.nullable && col.default.nil? then cells[col.name] = @domains.typical(table, col.name).first
          end
        end

        def fresh?(table, col)
          [nil, "identity"].include?(col.default) && @catalog.unique_keys(table).flatten.include?(col.name)
        end

        def fresh_value(table, column) = Typical.unique(@catalog.column(table, column).type, @fresh += 1)

        # A parent's own foreign key: NULL if it can be, else a row already
        # there, else new values that satisfy then builds a row for.
        def reference(table, link, cells, have)
          return link.columns.each { cells[it] = nil } if nullable?(table, link)

          row = have[link.parent].first
          link.columns.zip(link.parent_columns).each { |c, p| cells[c] = row ? row[p] : fresh_value(link.parent, p) }
        end

        def nullable?(table, link) = link.columns.all? { @catalog.column(table, it).nullable }

        def fixture_row(table, values)
          ArenaRunner::FixtureRow.new(table:, columns: values.keys, values: values.values)
        end
      end
    end
  end
end
