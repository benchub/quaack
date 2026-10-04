# frozen_string_literal: true

require "pg_query"
require_relative "arena_fixture"
require_relative "arena_schema"
require_relative "predicate_atoms"
require_relative "table_name"
require_relative "value_pools"
require_relative "scenarios/checks"
require_relative "scenarios/free_values"
require_relative "scenarios/picker"
require_relative "scenarios/plan"
require_relative "scenarios/reads"
require_relative "scenarios/row_set"
require_relative "scenarios/ties"
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
    # - copy: another row for one table, sharing another group's keys, but
    #   with its own value for a key its table holds unique.
    # - cross: a group whose row points one foreign key at the hit's parent
    #   (see Topology#crossings).
    # - orphan: one side of a join with no foreign key, alone (with the
    #   tables it references).
    # - boundary: the hit group, with type boundary values wherever they
    #   still satisfy the atoms and CHECKs.
    # - empty: only the tables that reference no other fixture table.
    #
    # The scenarios are S0: none; S1: hit and near misses; S2: S1 and nulls;
    # S3: S1, a copy of each table's hit row, and crosses; S4: S1 and orphans; S5: S1
    # and two boundary groups; S6: hit, a group with two more copies of each
    # table's row, and empty.
    #
    # Column values. A pooled atom's column takes the first pool value that
    # satisfies (or for its near miss, fails) the atom and satisfies every
    # other atom and CHECK on the column (see Picker). variants rotates an
    # atom's pool lists, by atom index, for 9c's retries. An atom no pool
    # value satisfies (r.id IS NULL on a NOT NULL key) is ignored, so
    # it can't drop every group. A key column takes
    # a generated value per group (an identity key too, when a key class
    # ties it to another column), and a unique column one per distinct
    # row, even with a DEFAULT. A unique index counts, a partial one as
    # always unique. Every column an expression unique index reads counts as
    # unique too, and RowSet evaluates the index's keys in Postgres to catch
    # rows whose expression values still collide (lower('A') = lower('a')).
    # An expression unique index that calls a function outside pg_catalog
    # raises Error(:expression_unique_index). Another column with a DEFAULT (or
    # an identity) is left out, so the default
    # applies. The rest take the type's typical value (0, '', the epoch),
    # or a value that satisfies the column's CHECKs. S1 has no NULLs but
    # those an atom needs (x IS NULL).
    #
    # Every row satisfies every validated constraint. A group whose row
    # can't, because it collides with an earlier row on a unique key, or no
    # value fails its near-miss atom, is left out, and 9c catches an atom
    # left vacuous. CHECKs must be simple (see Checks), or the build raises
    # Error(:complex_check). A foreign-key cycle between tables is broken
    # where it can be: a foreign key in the cycle whose columns are all
    # nullable, and that no atom reads, is cut (see Topology), and rows
    # leave its columns NULL. A cycle with no such foreign key raises
    # Error(:fk_cycle). Rows come table by table, parents first, each
    # table's rows together, as 9d's reverse load needs.
    #
    # Trust boundary: the rows hold real values and stay in the enclave.
    # Errors name a rule, and for unsupported_type and domain_check the
    # table, column, and type step 9 can't fill, which are schema, never a
    # row value.
    module Scenarios
      class Error < StandardError
        attr_reader :rule, :column, :cycle

        # column is { "table", "column", "type" }, as ErrorFilter sends it.
        # cycle is an fk_cycle's TableNames, in the order their foreign
        # keys point, ending with the first again.
        def initialize(rule, column: nil, cycle: nil)
          @rule = rule
          @column = column
          @cycle = cycle
          super(column ? "#{rule}: #{column["table"]}.#{column["column"]} (#{column["type"]})" : rule.to_s)
        end
      end

      NAMES = %i[s0 s1 s2 s3 s4 s5 s6].freeze

      # copy tells rows apart that are alike in every other way. cross, when
      # set, points one foreign key of the group's row at another group's
      # parent (see Cross).
      Group = Data.define(:key, :tables, :near, :split, :mode, :copy, :cross) do
        # The key a column of table takes in this group: the hit's where a
        # cross points it, the split table's own, and a copy's own where its
        # table's unique keys need one (own, see Topology#own_key?).
        def key_for(table, name, own:)
          return cross.key if cross&.points?(table, name)

          (split == table ? key + SPLIT_KEY : key) + (own ? COPY_KEY * copy : 0)
        end
      end
      GROUP_DEFAULTS = { near: nil, split: nil, mode: :plain, copy: 0, cross: nil }.freeze
      SPLIT_KEY = 100_000
      COPY_KEY = 200_000

      # A foreign key of table, on columns, whose row points at the parent
      # row in the group with key (the hit, which S3 holds).
      Cross = Data.define(:table, :columns, :key) do
        def points?(table, name) = self.table == table && columns.include?(name)
      end

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

        UNIQUE = FreeValues::UNIQUE

        def initialize(conn, parse)
          @conn = conn
          @parse = parse
          @schema = ArenaSchema.load_closure(conn, Scenarios.query_tables(parse.tree))
          raise Error, :expression_unique_index if @schema.tables.any? { |t| @schema.constraints(t).user_function }

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
          ties = tie_groups
          Plan.new(@topology, @atoms, @pools.keys).scenarios.to_h do |name, groups|
            [name, fill(groups.filter_map { |g| build_group(g) } + (TIE_SCENARIOS.include?(name) ? ties : []))]
          end
        end

        # The scenarios that build on S1's near misses, and so take the
        # keyset tie rows too.
        TIE_SCENARIOS = %i[s1 s2 s3 s4 s5].freeze
        TIE_KEY = 50_000

        private

        def order = @topology.order

        def probes
          @probes ||= @pools.keys.to_h do |i|
            column = @atoms[i].columns[0]
            col = @schema.column(column.table, column.name)
            [i, ValuePools.probe(@conn, @parse, @atoms[i], col)]
          end
        end

        def fill(row_groups)
          set = RowSet.new(@schema, @conn)
          row_groups.each { |rows| @dropped += 1 unless set.add?(rows) }
          set.in_order(order)
        end

        # For each pooled keyset row comparison, groups whose row ties it on
        # its leading columns (see Ties): a hit on the keyset's table and its
        # ancestors, with the tie columns set. A tie that would set a join
        # key or generated column, or break a CHECK, is left out.
        def tie_groups
          keysets = @atoms.values_at(*@pools.keys)
          Ties.all(@conn, @parse, keysets, @schema).each_with_index.filter_map do |(table, set), n|
            next unless tie_allowed?(table, set)

            build_group(Scenarios.group(TIE_KEY + n, @topology.ancestors(table)))&.then do |rows|
              Ties.apply(rows, table, set, @schema)
            end
          end
        end

        def tie_allowed?(table, overrides)
          overrides.none? do |name, v|
            @topology.keyed?(table, name) || !@checks.allows?(table, @schema.column(table, name), v)
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
          keyed = @topology.keyed?(table, col.name)
          # An identity column a key class ties to another takes the key's
          # value (the runner overrides the identity), or else its own.
          return :omit if generated?(col, keyed)
          # A cut foreign key's column: the load order ignores it.
          return nil if @topology.cut?(table, col.name)

          slot = @topology.slot(table, col.name)
          atoms = slot_atoms(slot)
          return nil if nulled?(group, col, keyed || atoms.any?)

          bound_value(slot, @picker.satisfiable(atoms), group, table, col)
        end

        # The value of a column no rule above settles: an atom's, a key's,
        # or a free one.
        def bound_value(slot, atoms, group, table, col)
          near = atoms.include?(group.near) ? group.near : nil
          return @picker.pick(atoms, slot_columns(slot), near, group.mode) if atoms.any?
          return key_value(slot, group, table, col.name) if @topology.keyed?(table, col.name)

          free_values.value(table, col, group.mode)
        end

        def free_values
          @free_values ||= FreeValues.new(@schema, @topology, @checks, @values,
                                          Reads.new(@parse, @schema.column_names)) { slot_atoms(it).any? }
        end

        def generated?(col, keyed) = col.default == "generated" || (col.default == "identity" && !keyed)

        def nulled?(group, col, constrained) = group.mode == :nulls && col.nullable && constrained

        def slot_atoms(slot)
          members = @topology.members(slot)
          @pools.keys.select { |i| members.include?([@pools[i].column.table, @pools[i].column.name]) }
        end

        def slot_columns(slot) = @topology.members(slot).map { |t, n| [t, @schema.column(t, n)] }

        # The key's value (see Group#key_for), one every column of the slot
        # reads.
        def key_value(slot, group, table, name)
          @values.shared_nth(slot_columns(slot), group.key_for(table, name, own: @topology.own_key?(table, name)))
        end

        # Unique columns get a value per distinct row: rows alike in every
        # other column, and in copy, are the same row.
        def identify(table, group, pairs)
          identity = [table, pairs.reject { |_, v| v.equal?(UNIQUE) }, group.copy]
          n = (@identities[identity] ||= @identities.size + 1)
          pairs.map do |name, v|
            v.equal?(UNIQUE) ? [name, @values.nth(@schema.column(table, name), n, table:)] : [name, v]
          end
        end
      end
    end
  end
end
