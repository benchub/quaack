# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # The atoms a masking near miss fails beside its own (see Plan). The
      # hit passes every arm of an OR and every branch of a UNION, so a near
      # miss that fails one atom of one arm still passes the others, and
      # the result can't change when that atom is replaced by TRUE. A
      # masking near miss also fails one atom of each other arm or branch,
      # one whose failing fails that arm: the arm itself, or an atom ANDed
      # into it, those on columns no other atom tests first. An arm that is NOT of an atom already fails, since the
      # group satisfies the atom. A branch or arm with no such atom (a
      # nested OR or UNION) leaves the atom with no masking near miss.
      #
      #   Branches.new(parse.tree, atoms, pooled).masked(topology.order) { |group| build_group(group) }
      #   # => { 2 => [5], 4 => [1, 7] }: each masked atom's also atoms
      class Branches
        def initialize(tree, atoms, pooled)
          @tree = tree
          @atoms = atoms
          @pooled = pooled
        end

        # The first atoms, one per masking arm, with which fits gives true,
        # chosen one arm at a time. Nil when nothing masks the atom.
        def also(index, &fits)
          options = masks(@atoms[index].path)
          return if options.nil? || options.empty?

          choose(options, fits, ahead: false) || choose(options, fits, ahead: true)
        end

        # Each pooled atom's also atoms, for the atoms an OR or UNION masks:
        # those whose near miss, a group over the tables in order, builds
        # gives rows for.
        def masked(order, &builds)
          @pooled.filter_map do |i|
            also(i) { builds.call(Scenarios.group(0, order, near: i, also: it)) }&.then { [i, it] }
          end.to_h
        end

        private

        # One atom per arm, each the first that fits beside those chosen
        # before it. A partial choice must satisfy the arms not yet chosen,
        # which can't be done when two of them are equalities on one column
        # (a = 1 OR a = 2 OR a = 3 OR ...), so when that finds none, ahead
        # tries each pick beside the first atom of every later arm too.
        def choose(options, fits, ahead:)
          options.each_with_index.with_object([]) do |(option, k), chosen|
            later = ahead ? options.drop(k + 1).map(&:first) : []
            pick = option.find { |j| fits.call(chosen + [j] + later) }
            return nil unless pick

            chosen << pick
          end
        end

        def dig(path) = path.reduce(@tree) { |node, step| node[step] }

        # For each OR or UNION above the path, for each other arm or branch,
        # the atoms that fail it: [] for one that already fails. Nil when one
        # has none.
        def masks(path)
          found = siblings(path).map { |prefix| failing(prefix) }
          found.reject(&:empty?) unless found.include?(nil)
        end

        def siblings(path)
          (1...path.size).flat_map do |k|
            if or_args?(path, k) then other_args(path, k)
            elsif union_branch?(path, k) then [path[0...k] + [path[k] == "larg" ? "rarg" : "larg"]]
            else []
            end
          end
        end

        def or_args?(path, step)
          path[step] == "args" && path[step - 1] == "bool_expr" &&
            dig(path[0...(step - 1)]).bool_expr.boolop == :OR_EXPR
        end

        def other_args(path, step)
          count = dig(path[0..step]).size
          (0...count).reject { it == path[step + 1] }.map { path[0..step] + [it] }
        end

        def union_branch?(path, step)
          Scenarios.select_step?(path, step) && path[step] != "select_stmt" && dig(path[0...step]).op == :SETOP_UNION
        end

        # The pooled atoms whose failing fails the arm or branch at prefix,
        # in query order. A branch is a SELECT, failed through its WHERE.
        def failing(prefix)
          return [] if negated_atom?(prefix)

          start = prefix.last.is_a?(Integer) ? prefix : prefix + ["where_clause"]
          found = @pooled.select { |j| within?(@atoms[j].path, start) }
          found.sort_by.with_index { |j, n| [shared(j), n] } unless found.empty?
        end

        # How many other pooled atoms test the atom's columns. Failing one
        # no other atom tests fails its arm alone, where failing a column
        # the query tests elsewhere too (o.kind = 'x' in each branch and
        # outside) would most likely fail those as well.
        def shared(index)
          columns = @atoms[index].columns
          @pooled.count { |j| j != index && @atoms[j].columns.intersect?(columns) }
        end

        def within?(path, start) = path[0...start.size] == start && anded?(path, start.size)

        # Whether the arm is NOT of one atom.
        def negated_atom?(prefix)
          return false unless prefix.last.is_a?(Integer) && dig(prefix).bool_expr&.boolop == :NOT_EXPR

          inner = prefix + %w[bool_expr args] + [0]
          @atoms.any? { it.path == inner }
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
