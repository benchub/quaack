# frozen_string_literal: true

require "pg_query"
require_relative "../arena_runner"
require_relative "../value_pools"

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
      # Each trial is 1 to 4 rows per table the scenarios load (one row a
      # table first, then up to two, then up to four), in the scenarios'
      # table order, parents first. A column takes a value some scenario row
      # holds for it, a value of an atom's pool, a boundary of its type,
      # true or false for a boolean, or NULL when it's nullable. A foreign
      # key picks a parent row the trial holds (or NULL when nullable), and
      # a unique column a value no earlier row of the table took. Each trial
      # loads in its own arena transaction that rolls back
      # (ArenaRunner#with_fixture), and is tested with the guard's own test
      # (VacuityGuard.exercised_atoms). A trial that won't load or whose
      # query fails (a constraint, a scalar subquery with two rows, the
      # statement timeout) is discarded: it tests nothing, and still counts
      # against the budget.
      #
      # The budget is TRIALS_PER_ATOM trials for each atom searched, and
      # SECONDS in all. An atom left when the trials run out was searched
      # with no difference found; one left when the clock or the fixture
      # cap (MAX_FIXTURES) stops the search wasn't searched in full. Neither
      # ever counts an atom tested. A query that calls a volatile function
      # isn't searched, since a difference could come from the function.
      # The generator is seeded with SEED, so a run is reproducible.
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
        # The share of the budget each trial size takes first: one row a
        # table, then up to two, then up to MAX_ROWS.
        SIZES = [[0.1, 1], [0.4, 2]].freeze
        VOLATILE = %w[random setseed clock_timestamp timeofday nextval setval gen_random_uuid uuid_generate_v1
                      uuid_generate_v4 txid_current pg_sleep].freeze
        STATES = %i[searched not_searched].freeze

        Outcome = Data.define(:fixtures, :found, :states, :trials, :discarded) do
          def inspect = "#<data #{self.class} found=#{found} states=#{states} fixtures=<redacted>>"

          alias_method :to_s, :inspect
        end

        AGGREGATES = %w[count sum avg min max array_agg string_agg bool_and bool_or every].freeze

        def self.volatile?(sql) = (PgQuery.parse(sql).functions & VOLATILE).any?

        # Whether a search's verdict could follow a literal (20261010-47): a
        # LIMIT or OFFSET, or an aggregate compared with a constant (a count
        # threshold past the rows a trial holds). Such queries aren't
        # searched.
        def self.literal_bound?(sql) = nodes(PgQuery.parse(sql).tree).any? { cut?(it) || threshold?(it) }

        def self.nodes(node, found = [])
          found << node
          ValuePools::Sides.children(node).each { nodes(it, found) }
          found
        end

        def self.cut?(node) = node.is_a?(PgQuery::SelectStmt) && !!(node.limit_count || node.limit_offset)

        def self.threshold?(node)
          return false unless node.is_a?(PgQuery::A_Expr) && node.lexpr && node.rexpr

          sides = [node.lexpr, node.rexpr]
          sides.any? { constant?(it) } && sides.any? { aggregate?(it) }
        end

        def self.constant?(node) = !!(node.a_const || node.type_cast&.arg&.a_const)

        def self.aggregate?(node)
          node = node.type_cast.arg if node.type_cast
          return aggregate_call?(node.func_call) if node.func_call

          select = node.sub_link&.subselect&.select_stmt
          !!select && select.target_list.any? { aggregate?(it.res_target.val) if it.res_target&.val }
        end

        def self.aggregate_call?(call)
          call.agg_star || AGGREGATES.include?(call.funcname.last&.string&.sval)
        end

        private_class_method :nodes, :cut?, :threshold?, :constant?, :aggregate?, :aggregate_call?
        # rubocop:disable Metrics/ParameterLists
        def initialize(runner, schema, order, sql, value_rows, pools, trials_per_atom: TRIALS_PER_ATOM,
                       seconds: SECONDS, seed: SEED, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
          # rubocop:enable Metrics/ParameterLists
          @runner = runner
          @schema = schema
          @sql = sql
          @values = values(value_rows, pools)
          @order = order.select { @values.key?(it) }
          @trials_per_atom = trials_per_atom
          @seconds = seconds
          @random = Random.new(seed)
          @clock = clock
        end

        def run(loosened)
          return outcome([], loosened.keys, :not_searched, 0, 0) if loosened.empty? || Search.volatile?(@sql) || Search.literal_bound?(@sql)

          search(loosened)
        end

        private

        def outcome(fixtures, left, state, trials, discarded)
          Outcome.new(fixtures: fixtures.map(&:first), found: fixtures.flat_map(&:last),
                      states: left.to_h { [it, state] }, trials:, discarded:)
        end

        def search(loosened)
          left = loosened
          budget = @trials_per_atom * loosened.size
          started = @clock.call
          kept = []
          trials = discarded = 0
          compared = Compared.new(MAX_COMPARISONS)
          while left.any? && trials < budget && @clock.call - started < @seconds && kept.size < MAX_FIXTURES
            rows = trial(size(trials, budget))
            trials += 1
            hit = test(rows, left, compared)
            next discarded += 1 if hit.nil?
            next if hit.empty?

            kept << [rows, hit]
            left = left.except(*hit)
          end
          outcome(kept, left.keys, trials >= budget ? :searched : :not_searched, trials, discarded)
        end

        # The atoms the trial tells apart, or nil when it's discarded.
        def test(rows, left, compared)
          VacuityGuard.exercised_atoms(@runner, rows, @sql, left, compared:)
        rescue ArenaRunner::Error => e
          raise if ArenaRunner::Cancel.foreign?(e)

          nil
        end

        def size(trials, budget) = SIZES.find { |share, _| trials < share * budget }&.last || MAX_ROWS

        def trial(max)
          present = {}
          @order.flat_map do |table|
            built = []
            used = Hash.new { |h, k| h[k] = [] }
            @random.rand(1..max).times { built << table_row(table, present, built, used) }
            present[table] = built
            built.map do |row|
              ArenaRunner::FixtureRow.new(table:, columns: row.keys, values: row.values, deferred: [])
            end
          end
        end

        def table_row(table, present, built, used)
          constraints = @schema.constraints(table)
          unique = constraints.uniques.flatten.uniq
          @values.fetch(table).to_h do |name, options|
            fk = constraints.foreign_keys.find { it.columns == [name] }
            [name, fk ? parent_value(table, name, fk, present, built) : pick(options, unique.include?(name), used[name])]
          end
        end

        def parent_value(table, name, fk, present, built)
          parents = fk.parent == table ? built : present.fetch(fk.parent, [])
          options = parents.map { it[fk.parent_columns.first] }
          options << nil if @schema.column(table, name).nullable || options.empty?
          options.sample(random: @random)
        end

        def pick(options, unique, used)
          return options.sample(random: @random) unless unique

          fresh = options - used
          (fresh.empty? ? options : fresh).sample(random: @random).tap { used << it }
        end

        # Each table's columns and the values a trial picks from.
        def values(value_rows, pools)
          sets = Hash.new { |h, k| h[k] = Hash.new { |c, n| c[n] = [] } }
          value_rows.each { |row| row.columns.zip(row.values).each { |c, v| sets[row.table][c] << v } }
          pools.each_value do |pool|
            next unless pool.respond_to?(:column) && sets.key?(pool.column.table)

            sets[pool.column.table][pool.column.name].concat([*pool.satisfying, *pool.failing, *pool.boundaries])
          end
          sets.each { |table, columns| widen(table, columns) }
          sets.to_h do |table, columns|
            [table, columns.to_h { |name, v| [name, v.compact.uniq + (@schema.column(table, name).nullable ? [nil] : [])] }]
          end
        end

        def widen(table, columns)
          @schema.columns(table).each do |col|
            next if %w[generated identity].include?(col.default) && !columns.key?(col.name)

            extra = col.type == "boolean" ? %w[true false] : ValuePools.boundaries(col.type)
            next if !columns.key?(col.name) && extra.empty?

            columns[col.name].concat(extra)
          end
        end
      end
    end
  end
end
