# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # How the fixture tables hang together: their load order (parents
      # first), and the key classes, sets of [table, column] tied together
      # by an equality join atom or a foreign key, which share one value.
      class Topology
        attr_reader :order

        def self.equality_join?(atom)
          atom.kind == :join && atom.operator == "=" && atom.bare && atom.columns.size == 2 &&
            atom.columns.all?(&:table)
        end

        def initialize(schema, atoms)
          @schema = schema
          @atoms = atoms
          @order = load_order
          @classes = key_classes
        end

        def parents(table) = foreign_keys(table).map(&:parent).uniq - [table]

        # The tables that reference no other fixture table.
        def roots = @order.select { |t| parents(t).empty? }

        # The table and every table it references, however far up, in load
        # order.
        def ancestors(table)
          found = [table]
          found.each { |t| parents(t).each { |p| found << p unless found.include?(p) } }
          @order & found
        end

        # The indexes of equality join atoms that no foreign key backs.
        def free_joins
          @atoms.each_index.select do |i|
            Topology.equality_join?(@atoms[i]) && @atoms[i].columns.none? { |c| fk_column?(c.table, c.name) }
          end
        end

        def keyed?(table, name) = @classes.key?([table, name])

        # The slot a column's value comes from: its key class's root, or
        # the column itself.
        def slot(table, name) = @classes.fetch([table, name], [table, name])

        def members(slot) = @classes.value?(slot) ? @classes.select { |_, root| root == slot }.keys : [slot]

        private

        def foreign_keys(table) = @schema.constraints(table).foreign_keys

        def fk_column?(table, name)
          @schema.tables.any? do |t|
            foreign_keys(t).any? do |fk|
              (t == table && fk.columns.include?(name)) || (fk.parent == table && fk.parent_columns.include?(name))
            end
          end
        end

        def load_order
          order = []
          pending = @schema.tables.dup
          until pending.empty?
            ready = pending.select { |t| (parents(t) - order).empty? }
            raise Error, :fk_cycle if ready.empty?

            order.concat(ready)
            pending -= ready
          end
          order
        end

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
            foreign_keys(t).flat_map { |fk| fk.columns.zip(fk.parent_columns).map { |c, p| [[t, c], [fk.parent, p]] } }
          end
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
