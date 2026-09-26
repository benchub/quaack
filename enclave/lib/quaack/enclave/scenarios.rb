# frozen_string_literal: true

require "pg_query"
require_relative "arena_fixture"
require_relative "arena_schema"
require_relative "predicate_atoms"
require_relative "table_name"
require_relative "value_pools"
require_relative "scenarios/checks"
require_relative "scenarios/picker"
require_relative "scenarios/plan"
require_relative "scenarios/row_set"
require_relative "scenarios/topology"
require_relative "scenarios/values"

module Quaack
  module Enclave
    # Step 9: scenarios S0 through S6, built from the value pools.
    #
    #   Scenarios.build(arena_connection, parse)                  # => { s0: [FixtureRow, ...], ..., s6: [...] }
    #   Scenarios.build(arena_connection, parse, variants: { 2 => 1 })
    #   builder = Scenarios::Builder.new(arena_connection, parse)  # atoms, pools, and build(variants)
    #
    # The fixture holds the query's plain tables and every table they
    # reference by foreign key. Rows are built in groups. A group has one
    # row per table, and its rows join each other: each set of columns tied
    # together by an equality join atom (a.k = b.k) or a foreign key shares
    # one key value per group. The groups:
    #
    # - hit: every pooled atom satisfied.
    # - near miss, one per pooled atom: that atom failed, every other one on
    #   the column still satisfied. And one per equality join atom that no
    #   foreign key backs: the right side's table gets a key of its own.
    # - nulls: every nullable join key and predicate column NULL.
    # - copy: another row for one table, sharing another group's keys.
    # - orphan: one side of a join with no foreign key, alone (with the
    #   tables it references).
    # - boundary: the hit group, with type boundary values wherever they
    #   still satisfy the atoms and CHECKs.
    # - empty: only the tables that reference no other fixture table.
    #
    # The scenarios are S0: none; S1: hit and near misses; S2: S1 and nulls;
    # S3: S1 and a copy of each table's hit row; S4: S1 and orphans; S5: S1
    # and two boundary groups; S6: hit, a group with two more copies of each
    # table's row, and empty.
    #
    # Column values. A pooled atom's column takes the first pool value that
    # satisfies (or for its near miss, fails) the atom and satisfies every
    # other atom and CHECK on the column (see Picker). variants rotates an
    # atom's pool lists, by atom index, for 9c's retries. A key column takes
    # a generated value per group, and a unique column one per distinct
    # row. Another column with a DEFAULT is left out, so the default
    # applies. The rest take the type's typical value (0, '', the epoch),
    # or a value that satisfies the column's CHECKs. S1 has no NULLs but
    # those an atom needs (x IS NULL).
    #
    # Every row satisfies every validated constraint. A group whose row
    # can't, because it collides with an earlier row on a unique key, or no
    # value fails its near-miss atom, is left out, and 9c catches an atom
    # left vacuous. CHECKs must be simple (see Checks), or the build raises
    # Error(:complex_check). A foreign-key cycle between tables raises
    # Error(:fk_cycle). Rows come table by table, parents first, each
    # table's rows together, as 9d's reverse load needs.
    #
    # Trust boundary: the rows hold real values and stay in the enclave.
    # Errors name only a rule.
    module Scenarios
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super(rule.to_s)
        end
      end

      NAMES = %i[s0 s1 s2 s3 s4 s5 s6].freeze

      # copy tells rows apart that are alike in every other way.
      Group = Data.define(:key, :tables, :near, :split, :mode, :copy)
      GROUP_DEFAULTS = { near: nil, split: nil, mode: :plain, copy: 0 }.freeze

      module_function

      def build(conn, parse, variants: {}) = Builder.new(conn, parse).build(variants)

      def group(key, tables, **) = Group.new(key:, tables:, **GROUP_DEFAULTS, **)

      # The type's boundary values a boundary group prefers, in its order,
      # or none for another group.
      def boundaries(type, mode)
        return [] unless mode.to_s.start_with?("boundary")

        values = ValuePools.boundaries(type)
        mode == :boundary_reversed ? values.reverse : values
      end

      # The plain tables a parse names.
      def query_tables(node, found = [])
        if node.is_a?(PgQuery::RangeVar) && !node.schemaname.empty?
          found << TableName.new(schema: node.schemaname, name: node.relname)
        end
        ValuePools::Sides.children(node).each { |c| query_tables(c, found) }
        found.uniq
      end

      # Builds the scenarios for one query.
      class Builder
        # dropped counts the groups the last build left out because they
        # collide on a unique key, over every scenario.
        attr_reader :atoms, :pools, :parse, :dropped

        UNIQUE = Object.new.freeze

        def initialize(conn, parse)
          @conn = conn
          @parse = parse
          @schema = ArenaSchema.load_closure(conn, Scenarios.query_tables(parse.tree))
          @atoms = PredicateAtoms.extract(parse, column_names: @schema.column_names)
          @pools = ValuePools.build(conn, parse, @atoms, @schema)
          @topology = Topology.new(@schema, @atoms)
          @checks = Checks.new(conn, @schema)
          @values = Values.new(conn)
        end

        def build(variants = {})
          @picker = Picker.new(@pools, probes, @checks, variants)
          @identities = {}
          @dropped = 0
          Plan.new(@topology, @atoms, @pools.keys).scenarios.transform_values do |groups|
            set = RowSet.new(@schema)
            groups.each { |g| build_group(g)&.then { |rows| @dropped += 1 unless set.add?(rows) } }
            set.in_order(order)
          end
        end

        private

        def order = @topology.order

        def probes
          @probes ||= @pools.keys.to_h do |i|
            column = @atoms[i].columns[0]
            col = @schema.column(column.table, column.name)
            [i, ValuePools::Probe.new(@conn, ValuePools.node(@parse, @atoms[i]), col)]
          end
        end

        # The group's rows, or nil when a near miss has no value.
        def build_group(group)
          rows = order.select { |t| group.tables.include?(t) }.map { |table| row(table, group) }
          rows unless rows.include?(:skip)
        end

        def row(table, group)
          pairs = @schema.columns(table).map { |col| [col.name, column_value(table, col, group)] }
          return :skip if pairs.any? { |_, v| v == :skip }

          pairs = identify(table, group, pairs.reject { |_, v| v == :omit })
          ArenaRunner::FixtureRow.new(table:, columns: pairs.map(&:first), values: pairs.map(&:last))
        end

        def column_value(table, col, group)
          return :omit if col.default == "generated"

          slot = @topology.slot(table, col.name)
          atoms = slot_atoms(slot)
          keyed = @topology.keyed?(table, col.name)
          return nil if nulled?(group, col, keyed || atoms.any?)
          return atom_value(slot, atoms, group) if atoms.any?
          return key_value(slot, group, table) if keyed

          free_value(table, col, group.mode)
        end

        def nulled?(group, col, constrained) = group.mode == :nulls && col.nullable && constrained

        def atom_value(slot, atoms, group)
          @picker.pick(atoms, slot_columns(slot), atoms.include?(group.near) ? group.near : nil, group.mode)
        end

        def free_value(table, col, mode)
          return UNIQUE if col.default.nil? && @schema.constraints(table).uniques.any? { |u| u.include?(col.name) }
          return :omit if col.default

          @checks.satisfying(table, col, Scenarios.boundaries(col.type, mode) + [@values.typical(col, strict: false)])
        end

        def slot_atoms(slot)
          members = @topology.members(slot)
          @pools.keys.select { |i| members.include?([@pools[i].column.table, @pools[i].column.name]) }
        end

        def slot_columns(slot) = @topology.members(slot).map { |t, n| [t, @schema.column(t, n)] }

        def key_value(slot, group, table)
          key = group.split == table ? group.key + 100_000 : group.key
          @values.nth(slot_columns(slot).first.last, key)
        end

        # Unique columns get a value per distinct row: rows alike in every
        # other column, and in copy, are the same row.
        def identify(table, group, pairs)
          identity = [table, pairs.reject { |_, v| v.equal?(UNIQUE) }, group.copy]
          n = (@identities[identity] ||= @identities.size + 1)
          pairs.map { |name, v| v.equal?(UNIQUE) ? [name, @values.nth(@schema.column(table, name), n)] : [name, v] }
        end
      end
    end
  end
end
