# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "../predicate_atoms"
require_relative "reach"
require_relative "uncut"

module Quaack
  module Enclave
    module Fuzz
      # Which of the original's predicate atoms (PredicateAtoms) the fuzz
      # search's and enumerate's worlds showed both true and false (task
      # 20261012-4, DESIGN.md's rewrite-test).
      #
      #   coverage = Coverage.new(atoms, original)
      #   coverage.observe(session)  # after each compared trial that didn't kill
      #   coverage.result            # => Result(atoms: 3, untested_atoms: [2], ...)
      #
      # It judges by replacement, on the original with every LIMIT, OFFSET,
      # and FETCH FIRST removed (Uncut), since which rows a page keeps
      # follows the cut's literal. On a compared world, that uncut original
      # with an atom replaced by TRUE (PredicateAtoms.with_value) giving a
      # result the official comparison calls a mismatch with the uncut
      # original's shows the atom wasn't true somewhere it mattered;
      # replaced by FALSE, that it wasn't false (Differ). An atom seen both
      # ways is tested, even if the rows that showed it fall outside the
      # original's page. Rows equal to the original's, a comparison that
      # refuses, or a query that fails see nothing, so it can only call an
      # atom untested that in fact came out both ways, never the other way
      # round. An atom with_value can't replace (a USING column, a NATURAL
      # JOIN marker, a deparse it can't trust) is untested, and so is every
      # atom of a query Reach.whole_worst_case? names, each threshold atom
      # (Reach.threshold_paths) and every atom in or holding one (the rest
      # are judged with each threshold replaced by TRUE, the same for every
      # literal: task 20261011-7), or every atom of one whose uncut original
      # doesn't deparse faithfully or whose cut holds more than a constant
      # or a parameter (Uncut), with nothing checked.
      #
      # A direction is checked only until it's seen: on each world up to
      # twice FIRST, then on FIRST worlds in each doubling of the count
      # after that (Coverage.due?), every pending direction in one
      # statement (Differ), so a direction no world shows costs a few
      # hundred statements in a long search, never one per trial.
      #
      # Trust boundary: Result's shapes are PredicateAtoms' redacted shapes;
      # the worlds and results stay in Session.
      class Coverage
        FIRST = 32

        # atoms counts the original's atoms. untested_atoms are the untested
        # ones' indexes into PredicateAtoms.extract's list, untested_shapes
        # their redacted shapes, and untested_paths their paths into the
        # original's parse, for AtomPosition.
        Result = Data.define(:atoms, :untested_atoms, :untested_shapes, :untested_paths)

        def initialize(atoms, original, binding = nil)
          @atoms = atoms
          @pending = Reach.whole_worst_case?(original, binding) ? {} : pending(original, binding)
          @seen = Hash.new { |h, k| h[k] = Set.new }
          @observed = 0
        end

        # Checks each pending direction on the world session's last trial
        # compared, if this observation is due.
        def observe(session)
          return if @pending.empty? || !Coverage.due?(@observed += 1)

          directions = @pending.keys
          session.differing(@original, @pending.values).each do |at|
            index, value = directions[at]
            @seen[index] << value
            @pending.delete([index, value])
          end
        end

        def result
          untested = @atoms.each_index.reject { @seen[it].size == 2 }
          Result.new(atoms: @atoms.size, untested_atoms: untested, untested_shapes: untested.map { @atoms[it].shape },
                     untested_paths: untested.map { @atoms[it].path })
        end

        # Whether the count-th world observed is checked.
        def self.due?(count)
          return true if count <= FIRST

          spacing = 2**Math.log2(count / FIRST).floor
          (count % spacing).zero?
        end

        private

        # The original uncut, and each replaceable atom's two loosened
        # queries of it, by [index, value]; none, so every atom untested,
        # when Uncut can't give the uncut original.
        def pending(original, binding)
          parse = Uncut.parse(original)
          thresholds = Reach.threshold_paths(parse.tree, binding)
          parse = unthresholded(parse, thresholds) unless thresholds.empty?
          @original = parse.query
          loosened(parse, thresholds)
        rescue Deparse::Error
          {}
        end

        # The parse with each threshold replaced by TRUE, the same for every
        # literal (task 20261011-7), its atoms' paths kept.
        def unthresholded(parse, thresholds)
          tree = Deparse.copy(parse.tree)
          thresholds.each do |path|
            path[0...-1].reduce(tree) { |node, step| node[step] }[path.last] =
              PgQuery::Node.new(a_const: PgQuery::A_Const.new(boolval: PgQuery::Boolean.new(boolval: true)))
          end
          Deparse.faithful_parse(tree)
        end

        # An atom that is a threshold, holds one, or sits inside one gets the
        # worst case: whether a world reaches it follows the literal.
        def threshold_scoped?(atom, thresholds)
          thresholds.any? { |at| atom.path.first(at.size) == at || at.first(atom.path.size) == atom.path }
        end

        def loosened(parse, thresholds)
          @atoms.each_with_index.with_object({}) do |(atom, index), pending|
            next if threshold_scoped?(atom, thresholds)

            [true, false].each { pending[[index, it]] = PredicateAtoms.with_value(parse, atom, it) }
          rescue PredicateAtoms::Error, Deparse::Error
            next
          end
        end
      end
    end
  end
end
