# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # The parents that get an unmatched group (see Plan#unmatched): a
      # group with a parent's row and its ancestors, and no row of the
      # child. Every other group joins each child to its parent, so an
      # outer or anti join on that foreign key never sees a parent left
      # unmatched, and loosening the join atom changes nothing.
      #
      # A foreign-key-backed equality join atom, between a child and a
      # parent table, gets one when the child is optional to the query: on
      # the side an outer join fills with NULLs (LEFT JOIN's right, RIGHT
      # JOIN's left, either of a FULL JOIN's), or in a subquery the parent
      # is outside of (a correlated EXISTS, NOT EXISTS, or scalar
      # subquery). An inner join, or a join inside one subquery, gets none,
      # so its scenarios don't change.
      #
      #   Unmatched.new(parse.tree, atoms, topology).tables  # => [[users]]: the tables of each unmatched group
      class Unmatched
        OUTER = { JOIN_LEFT: %w[rarg], JOIN_RIGHT: %w[larg], JOIN_FULL: %w[larg rarg] }.freeze

        def initialize(tree, atoms, topology)
          @tree = tree
          @atoms = atoms
          @topology = topology
        end

        def tables = @atoms.filter_map { |atom| parent_tables(atom) }.uniq

        private

        def parent_tables(atom)
          return unless Topology.equality_join?(atom)

          child, parent = ends(atom.columns.map(&:table))
          return unless child && optional?(atom.path, child, parent)

          found = @topology.ancestors(parent)
          found unless found.include?(child)
        end

        # The child and the parent, when one of the two references the
        # other and not the other way round.
        def ends(pair)
          one, other = pair
          return if one == other

          down = @topology.parents(one).include?(other)
          up = @topology.parents(other).include?(one)
          return [one, other] if down && !up

          [other, one] if up && !down
        end

        # Whether the innermost outer join or subquery the atom sits in
        # leaves the child optional.
        def optional?(path, child, parent)
          step = path.each_index.reverse_each.find { |k| %w[join_expr sub_link].include?(path[k]) }
          return false unless step

          node = dig(path[0..step])
          path[step] == "join_expr" ? outer_side?(node, path[step + 1], child) : correlated?(node, child, parent)
        end

        def correlated?(sub_link, child, parent)
          inside = Scenarios.query_tables(sub_link.subselect)
          inside.include?(child) && !inside.include?(parent)
        end

        def outer_side?(join, field, child)
          sides = OUTER.fetch(join.jointype, [])
          field == "quals" && sides.any? { |side| Scenarios.query_tables(join[side]).include?(child) }
        end

        def dig(path) = path.reduce(@tree) { |node, step| node[step] }
      end
    end
  end
end
