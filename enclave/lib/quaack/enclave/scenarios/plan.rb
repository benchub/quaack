# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # Which groups make up each scenario (see Scenarios).
      class Plan
        # masked maps an atom to its masking near miss's also atoms.
        # siblings maps an atom to the table whose near-miss row gets a
        # sibling (see #siblings).
        # tree is the query's parse tree, for the unmatched groups (see
        # Unmatched); without it there are none.
        def initialize(topology, atoms, pooled, masked = {}, siblings = {}, tree = nil) # rubocop:disable Metrics/ParameterLists
          @topology = topology
          @atoms = atoms
          @pooled = pooled
          @masked = masked
          @siblings = siblings
          @unmatched = tree ? Unmatched.new(tree, atoms, topology).entries : []
          @alone = tree ? Plan.uncut_limit?(tree) : false
          @next_key = 0
        end

        # S1's near misses (pooled, join, and masking), for a fixture of
        # their own with no hit, once scenarios has run; none unless the
        # query's top level has a LIMIT and no ORDER BY.
        attr_reader :near_misses_alone

        def scenarios
          hit = group(fresh_key)
          near = pooled_near_misses
          base = [hit, *near, *join_near_misses]
          extras = { s1: [], s2: [nulls], s3: fan_outs(hit, near), s4: orphans, s5: boundaries }
          last = last_groups(hit, near)
          { s0: [], **extras.transform_values { base + it + last }, s6: [hit] + many + [empty] }
        end

        # Whether the top-level SELECT has a LIMIT and no ORDER BY. Its
        # result then holds as many rows as match, up to the LIMIT, whichever
        # they are: with the hit present, SELECT 1 ... LIMIT 1 returns one
        # row however many near misses a loosened condition lets through.
        def self.uncut_limit?(tree)
          select = tree.stmts.first&.stmt&.select_stmt
          !!(select&.limit_count && select.sort_clause.empty?)
        end

        private

        # The masking near misses, then the near misses' siblings, then the
        # unmatched groups. Sets near_misses_alone too.
        def last_groups(hit, near)
          masking = masking_near_misses
          @near_misses_alone = @alone ? near + @joins + masking : []
          masking + siblings(near + masking) + unmatched(hit)
        end

        # For each parent an outer or anti join can leave unmatched, a group
        # of the parent's tables alone, with no row of the child: one with
        # every atom satisfied, and a near miss for each pooled atom on those
        # tables, so an atom on the parent changes which unmatched parents
        # the query returns. Last, after the masking near misses, so their
        # keys come after every other group's. A count's threshold gives the
        # hit's parent more children (see more_children).
        def unmatched(hit)
          @unmatched.flat_map do |entry|
            tables = entry.tables
            near = @pooled.select { |i| @atoms[i].columns.all? { tables.include?(it.table) } }
            next unreferenced(entry, hit, near) if entry.cross

            [*more_children(entry, hit), *[nil, *near].map { |i| group(fresh_key, tables, near: i) }]
          end
        end

        # Copies of the hit's child row, numbered from MORE_CHILDREN_COPY,
        # past S3's and S6's copies, so they don't collide with them, and
        # Builder#fill can leave them out of dropped.
        def more_children(entry, hit)
          (1...entry.children).map { group(hit.key, [entry.child], copy: MORE_CHILDREN_COPY + it - 1) }
        end

        # A self-reference's unmatched row: a cross that points at the
        # hit's row, so no row points at it, and one per pooled near miss.
        def unreferenced(entry, hit, near)
          [nil, *near].map { |i| cross(entry.child, entry.cross, hit.key, near: i) }
        end

        # A near miss whose atom's column is tested in another scope too
        # (s.state <> 'x' in a subquery's branch and outside it) fails both,
        # so its parent's row drops out of the outer query with it. A
        # sibling is a second row of the atom's table under the same parent
        # (the near miss's key, a copy's own unique keys) that passes the
        # atom: the outer query reaches the parent through it, so loosening
        # the atom changes what the parent's other scope sees. It fails the
        # near miss's also atoms, so a masked branch still fails.
        def siblings(misses)
          misses.filter_map do |miss|
            table = @siblings[miss.near]
            group(miss.key, [table], copy: 1, also: miss.also | scope_mate(miss.near, table)) if table
          end
        end

        # One other pooled atom of the near miss's scope on table, on another
        # column, for the sibling to fail, so the sibling doesn't satisfy the
        # scope the near miss fails (a branch's score > 5 beside its
        # kind <> 'c'), which would let the parent through it all the same.
        def scope_mate(index, table)
          scopes = Scenarios.scopes(@atoms)
          mate = @pooled.find do |j|
            j != index && scopes[j] == scopes[index] && @atoms[j].columns.all? { it.table == table } &&
              !names(j).intersect?(names(index))
          end
          mate ? [mate] : []
        end

        def names(index) = @atoms[index].columns.map { [it.table, it.name] }

        def pooled_near_misses = @pooled.map { |i| group(fresh_key, near: i) }

        # Last in each scenario that holds them, so a unique-key collision
        # leaves them out before any other group.
        def masking_near_misses = @masked.map { |i, also| group(fresh_key, near: i, also:) }

        def nulls = group(fresh_key, mode: :nulls)

        def empty = group(fresh_key, @topology.roots)

        # Crosses come first, so that when a unique column's filter leaves
        # one value after the hit's, a cross takes it.
        def fan_outs(hit, near) = crosses(hit, near) + copies(hit)

        def copies(hit) = order.map { |t| group(hit.key, [t], copy: 1) }

        # For each foreign key a row can point across groups (see
        # Topology#crossings), a group whose row points it at the hit's
        # parent, not its own, with no parent of its own that nothing else
        # needs, and all its children for a cut key (see Topology#cross_tables). A key the table holds unique
        # can't point at the hit's parent, which has its child, so it
        # points at a parent of its own group's, with no child (a has_one).
        # A self-reference points at a row of its own table, and is crossed
        # with each near miss too: a row that fails the atom, pointing at the
        # hit's, so a filter on the child and one on its parent differ.
        def crosses(hit, near)
          @topology.crossings.flat_map do |table, foreign|
            parent = childless_parent(table, foreign)
            plain = cross(table, foreign, parent&.key || hit.key)
            self_references?(table, foreign) ? [plain] + near_crosses(table, foreign, hit, near) : [*parent, plain]
          end
        end

        def childless_parent(table, foreign)
          return unless @topology.unique_key?(table, foreign) && !self_references?(table, foreign)

          group(fresh_key, @topology.ancestors(foreign.parent))
        end

        def near_crosses(table, foreign, hit, near)
          near.map { |miss| cross(table, foreign, hit.key, near: miss.near) }
        end

        def cross(table, foreign, target, **)
          across = Cross.new(table:, columns: foreign.columns, key: target)
          group(fresh_key, @topology.cross_tables(table, foreign), cross: across, **)
        end

        def self_references?(table, foreign) = foreign.parent == table

        # The reversed group comes first, so its larger values go with the
        # smaller keys, and an ORDER BY on a boundary value can't agree with
        # one on the keys.
        def boundaries = %i[boundary_reversed boundary].map { |mode| group(fresh_key, mode:) }

        def order = @topology.order

        def fresh_key = @next_key += 1

        def group(key, tables = order, **) = Scenarios.group(key, tables, **)

        def many
          key = fresh_key
          [group(key)] + [1, 2].product(order).map { |copy, t| group(key, [t], copy:) }
        end

        def join_near_misses
          @joins = @topology.free_joins.map { |i| group(fresh_key, split: @atoms[i].columns[1].table) }
        end

        def orphans
          @topology.free_joins.flat_map do |i|
            @atoms[i].columns.map(&:table).uniq.map { |t| group(fresh_key, @topology.ancestors(t)) }
          end
        end
      end
    end
  end
end
