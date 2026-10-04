# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # How the fixture tables hang together: their load order (parents
      # first), and the key classes, sets of [table, column] tied together
      # by an equality join atom or a foreign key, which share one value.
      #
      # A foreign key that references its own table is left out of the
      # load order. A foreign-key cycle is broken by cutting foreign keys
      # whose child columns are all nullable from the load order, one at a
      # time while it still closes a cycle: first those no atom reads, then
      # the rest. A cut foreign key's columns still join its key class and
      # get their scenario values, but fixture rows defer them
      # (ArenaRunner::FixtureRow#deferred): they load as NULL and are set
      # once every row has loaded. A cut foreign key's columns are NULL in
      # a group that leaves out its parent's table. A cycle with no
      # nullable foreign key left raises Error(:fk_cycle), naming one such
      # cycle's tables.
      class Topology
        attr_reader :order

        def self.equality_join?(atom)
          atom.kind == :join && atom.operator == "=" && atom.bare && atom.columns.size == 2 &&
            atom.columns.all?(&:table)
        end

        def initialize(schema, atoms)
          @schema = schema
          @atoms = atoms
          @cut = cut_foreign_keys
          @order = load_order
          @classes = key_classes
        end

        # The table's columns that belong to a cut foreign key, which
        # fixture rows defer.
        def cut_columns(table) = @cut.fetch(table, []).flat_map(&:columns).uniq

        # Every table the table references, cut or not, but itself.
        def parents(table) = all_foreign_keys(table).map(&:parent).uniq - [table]

        # The tables that reference no other fixture table through a foreign
        # key the load order keeps.
        def roots = @order.select { |t| load_parents(t).empty? }

        # Whether the column belongs to a cut foreign key whose parent's
        # table the group leaves out, as the empty group and a copy of one
        # table's row do, so it must be NULL, unless the group's cross
        # points it at the hit's parent. A copy's parent row may not
        # exist: when the parent's table has a column no value fits (c.id IS
        # NULL), its copy and the hit never build, but other tables' copies
        # still reference this table's copy.
        def null_cut?(table, name, group)
          return false if group.cross&.points?(table, name)

          @cut.fetch(table, []).any? { |fk| fk.columns.include?(name) && !group.tables.include?(fk.parent) }
        end

        # The table and every table it references, however far up, in load
        # order.
        def ancestors(table)
          found = [table]
          found.each { |t| parents(t).each { |p| found << p unless found.include?(p) } }
          @order & found
        end

        # The tables a cross group on the table's foreign key needs: the
        # table and the ancestors its other foreign keys lead to. The cross
        # points the key at another group's parent, so the group holds its
        # own only when another path reaches it.
        def cross_tables(table, foreign)
          others = (foreign_keys(table) - [foreign]).map(&:parent).uniq - [table]
          @order & [table, *others.flat_map { |p| ancestors(p) }]
        end

        # The indexes of equality join atoms that no foreign key backs.
        def free_joins
          @atoms.each_index.select do |i|
            Topology.equality_join?(@atoms[i]) && @atoms[i].columns.none? { |c| fk_column?(c.table, c.name) }
          end
        end

        def keyed?(table, name) = @classes.key?([table, name])

        # Each [table, foreign key] whose row can point at another group's
        # parent: a foreign key to another table, cut or not, that shares
        # no column with another of the table's foreign keys. A cut one
        # gives two rows that share a parent, though the hit's row points
        # at its own group's.
        def crossings
          @order.flat_map do |t|
            fks = all_foreign_keys(t).reject { |fk| fk.parent == t }
            fks.select { |fk| (fks - [fk]).none? { |o| o.columns.intersect?(fk.columns) } }.map { |fk| [t, fk] }
          end
        end

        # The slot a column's value comes from: its key class's root, or
        # the column itself.
        def slot(table, name) = @classes.fetch([table, name], [table, name])

        def members(slot) = @classes.value?(slot) ? @classes.select { |_, root| root == slot }.keys : [slot]

        # Whether a copy of the table's row takes a key of its own for the
        # column, rather than the row's. A copy can't repeat a value that a
        # unique key of its table holds, so the slots of those columns get
        # the copy's key, and a self-reference follows its row. The table's
        # foreign keys to other tables still point at the row's parents, so
        # the parents get a second child.
        def own_key?(table, name)
          keyed?(table, name) && own_slots(table).include?(slot(table, name))
        end

        private

        def all_foreign_keys(table) = @schema.constraints(table).foreign_keys

        # The columns of the table's foreign keys to other tables.
        def outward(table) = foreign_keys(table).reject { |fk| fk.parent == table }.flat_map(&:columns)

        def own_slots(table)
          (@schema.constraints(table).uniques.flatten.uniq - outward(table))
            .select { |c| keyed?(table, c) }.map { |c| slot(table, c) }
        end

        def foreign_keys(table) = all_foreign_keys(table) - @cut.fetch(table, [])

        def load_parents(table) = foreign_keys(table).map(&:parent).uniq - [table]

        # Greedy, so every cut foreign key closed a cycle when it was cut,
        # and any cycle left has no nullable foreign key.
        def cut_foreign_keys
          unread, read = cut_candidates.partition { |t, fk| fk.columns.none? { |c| read?(t, c) } }
          (unread + read).each_with_object({}) do |(t, fk), cut|
            (cut[t] ||= []) << fk if reaches?(fk.parent, t, cut)
          end
        end

        # Each [table, foreign key] whose child columns are all nullable,
        # but for one that references its own table.
        def cut_candidates
          @schema.tables.flat_map do |t|
            all_foreign_keys(t).select { |fk| fk.parent != t && nullable?(t, fk) }.map { |fk| [t, fk] }
          end
        end

        def nullable?(table, foreign) = foreign.columns.all? { |c| @schema.column(table, c).nullable }

        def read?(table, name) = @atoms.any? { |a| a.columns.any? { |c| c.table == table && c.name == name } }

        # Whether to is from, or a table from references, however far up,
        # through foreign keys not yet cut.
        def reaches?(from, to, cut)
          found = [from]
          found.each do |t|
            (all_foreign_keys(t) - cut.fetch(t, [])).each { |fk| found << fk.parent unless found.include?(fk.parent) }
          end
          found.include?(to)
        end

        def fk_column?(table, name)
          @schema.tables.any? do |t|
            all_foreign_keys(t).any? do |fk|
              (t == table && fk.columns.include?(name)) || (fk.parent == table && fk.parent_columns.include?(name))
            end
          end
        end

        def load_order = LoadOrder.new(@schema.tables) { load_parents(it) }.call

        def key_classes
          union = UnionFind.new
          (join_edges + fk_edges).each { |one, other| union.join(one, other) }
          union.roots
        end

        def join_edges
          @atoms.select { |a| Topology.equality_join?(a) }.map { |a| a.columns.map { |c| [c.table, c.name] } }
        end

        def fk_edges
          @schema.tables.flat_map do |t|
            all_foreign_keys(t).flat_map do |fk|
              fk.columns.zip(fk.parent_columns).map { |c, p| [[t, c], [fk.parent, p]] }
            end
          end
        end
      end

      # Tables in load order, parents first, given each table's parents.
      # A cycle raises Error(:fk_cycle), naming one cycle's tables.
      class LoadOrder
        def initialize(tables, &parents)
          @tables = tables
          @parents = parents
        end

        def call
          order = []
          pending = @tables.dup
          until pending.empty?
            ready = pending.select { |t| (@parents.call(t) - order).empty? }
            raise Error.new(:fk_cycle, cycle: cycle(pending)) if ready.empty?

            order.concat(ready)
            pending -= ready
          end
          order
        end

        private

        # One cycle among pending, every one of which has a parent still
        # pending: from the first, follow the first pending parent until a
        # table comes round again. The tables from that one on, in the
        # order their foreign keys point, end with it again.
        def cycle(pending)
          walk = [pending.first]
          walk << @parents.call(walk.last).find { pending.include?(it) } until walk.count(walk.last) == 2
          walk.drop(walk.index(walk.last))
        end
      end

      # A plain union-find.
      class UnionFind
        def initialize = @parent = {}

        def join(one, other)
          @parent[find(one)] = find(other)
        end

        def find(item)
          @parent[item] ||= item
          @parent[item] == item ? item : find(@parent[item])
        end

        # Each item, with its class's root.
        def roots = @parent.keys.to_h { |x| [x, find(x)] }
      end
    end
  end
end
