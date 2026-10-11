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
      # parent, gets one when the child is optional to the query: on the
      # side an outer join fills with NULLs (LEFT JOIN's right, RIGHT
      # JOIN's left, either of a FULL JOIN's), or in a subquery the parent
      # is outside of (a correlated EXISTS, NOT EXISTS, or scalar
      # subquery, or a LATERAL subquery in FROM). Child and parent are told
      # apart by the names the query gives them, so a self-reference under
      # two aliases (e.manager_id = u.id) gets one too: a cross whose key
      # points at the hit's row, so no row points at it. An inner join, or
      # a join inside one subquery, gets none, so its scenarios don't
      # change. Neither does an outer join whose WHERE never passes the
      # child's NULLs (see Unmatched::Rejects).
      #
      # A correlated count's threshold, (SELECT count(*) ...) > 2, gets no
      # more children in v1, so its join atom may stay untested: how many
      # children the fixtures held would follow the literal, and so would
      # what rewrite-test reports (the fixtures it loads).
      #
      #   Unmatched.new(parse.tree, atoms, topology).entries
      #   # => [Entry(tables: [users], child: posts, cross: nil)]
      class Unmatched
        OUTER = { JOIN_LEFT: %w[rarg], JOIN_RIGHT: %w[larg], JOIN_FULL: %w[larg rarg] }.freeze

        # An unmatched parent's tables, the child's table, and a
        # self-reference's foreign key (nil for any other).
        Entry = Data.define(:tables, :child, :cross)

        def initialize(tree, atoms, topology)
          @tree = tree
          @atoms = atoms
          @topology = topology
        end

        # One per parent's tables and child: a parent with two optional
        # children (its posts and the users who report to it) gets one for
        # each.
        def entries = @atoms.filter_map { |atom| entry(atom) if Topology.equality_join?(atom) }.uniq

        private

        def entry(atom)
          child, parent, cross = ends(atom.columns)
          return unless child && optional?(atom, child, parent)

          table = child.table
          return Entry.new(tables: [table], child: table, cross:) if cross

          found = @topology.ancestors(parent.table)
          Entry.new(tables: found, child: table, cross:) unless found.include?(table)
        end

        # The child's column, the parent's, and for a self-reference its
        # foreign key, when one of the two tables references the other and
        # not the other way round.
        def ends(columns)
          one, other = columns
          return self_reference(one, other) if one.table == other.table

          down = @topology.parents(one.table).include?(other.table)
          up = @topology.parents(other.table).include?(one.table)
          return [one, other] if down && !up

          [other, one] if up && !down
        end

        # The single-column foreign key from a table to itself that the atom
        # tests under two names, with the child's column first.
        def self_reference(one, other)
          return if one.refname == other.refname

          own = @topology.crossings.filter_map { |t, fk| fk if t == one.table && fk.parent == t }
          found = own.product([[one, other], [other, one]]).find { |fk, pair| points?(fk, *pair) }
          [*found[1], found[0]] if found
        end

        def points?(foreign, child, parent) = foreign.columns == [child.name] && foreign.parent_columns == [parent.name]

        # Whether the innermost outer join, subquery, or LATERAL subquery in
        # FROM the atom sits in leaves the child optional.
        def optional?(atom, child, parent)
          path = atom.path
          step = path.each_index.reverse_each.find { |k| inner?(path, k) }
          return false unless step

          node = dig(path[0..step])
          return outer_side?(node, path[step + 1], atom, child) if path[step] == "join_expr"

          correlated?(path[step] == "sub_link" ? node.subselect : node.subquery, child, parent)
        end

        def correlated?(subquery, child, parent)
          inside = refnames(subquery)
          inside.include?(child.refname) && !inside.include?(parent.refname)
        end

        def inner?(path, step)
          %w[join_expr sub_link].include?(path[step]) ||
            (path[step] == "range_subselect" && dig(path[0..step]).lateral)
        end

        def outer_side?(join, field, atom, child)
          sides = OUTER.fetch(join.jointype, [])
          field == "quals" && sides.any? { refnames(join[it]).include?(child.refname) } &&
            !Rejects.new(@tree, @atoms).rejected?(atom, child)
        end

        # The names a node's FROM items go by, at any depth.
        def refnames(node, found = [])
          found << (node.alias ? node.alias.aliasname : node.relname) if node.is_a?(PgQuery::RangeVar)
          ValuePools::Sides.children(node).each { |c| refnames(c, found) }
          found.uniq
        end

        def dig(path) = path.reduce(@tree) { |node, step| node[step] }

        # Whether an outer join's WHERE never passes its NULL-filled rows:
        # an atom ANDed into the WHERE of the join's SELECT that's never
        # true on a NULL in the child's columns (WHERE o.state = 'x' after
        # LEFT JOIN o). Only the bare tests STRICT names count, so anything
        # else (IS NULL, IS DISTINCT FROM, <> ALL, coalesce, an OR) keeps
        # the group. The other groups test such a join as they would an
        # inner one. IS NOT NULL keeps it too: on a NOT NULL key
        # (o.id IS NOT NULL, Rails' where.not(o: { id: nil })) the
        # unmatched parent is the only row that fails it.
        class Rejects
          # By kind, the operators never true on NULL: nil for every one.
          # NULL <> ALL('{}') is true, so <> ALL isn't here.
          STRICT = { equality: %w[= <>], range: nil, like: nil, in: ["IN", "NOT IN", "= ANY"] }.freeze

          def initialize(tree, atoms)
            @tree = tree
            @atoms = atoms
          end

          def rejected?(join_atom, child)
            where = Scenarios.scope(join_atom) + ["where_clause"]
            @atoms.any? { |atom| strict?(atom) && in_where?(atom.path, where) && reads?(atom, child) }
          end

          private

          def in_where?(path, where) = path[0...where.size] == where && anded?(path, where.size)

          def reads?(atom, child) = atom.columns.any? { it.table == child.table && it.refname == child.refname }

          def dig(path) = path.reduce(@tree) { |node, step| node[step] }

          def strict?(atom)
            return false unless atom.bare && STRICT.key?(atom.kind)

            ops = STRICT[atom.kind]
            ops.nil? || ops.include?(atom.operator)
          end

          # Whether the path's steps from start on run only through ANDs.
          def anded?(path, start)
            rest = path[start..]
            return false unless (rest.size % 3).zero?

            rest.each_slice(3).with_index.all? do |(field, args, i), n|
              field == "bool_expr" && args == "args" && i.is_a?(Integer) &&
                dig(path[0...(start + (3 * n))]).bool_expr.boolop == :AND_EXPR
            end
          end
        end
      end
    end
  end
end
