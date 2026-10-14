# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "../predicate_atoms"
require_relative "reach"

module Quaack
  module Enclave
    module Fuzz
      # Which of the original's predicate atoms (PredicateAtoms) the fuzz
      # search's and enumerate's worlds showed both true and false (task
      # 20261012-4, DESIGN.md's rewrite-test).
      #
      #   coverage = Coverage.new(session, atoms, original)
      #   coverage.observe(session)  # after each compared trial that didn't kill
      #   coverage.result            # => Result(atoms: 3, untested_atoms: [2], ...)
      #
      # It judges by replacement. On a compared world, the original with an
      # atom replaced by TRUE (PredicateAtoms.with_value) giving a result
      # the official comparison calls a mismatch with the original's shows
      # the atom wasn't true somewhere it mattered; replaced by FALSE, that
      # it wasn't false. An atom seen both ways is tested. Rows equal to
      # the original's, a comparison that refuses, or a query that fails
      # see nothing, so it can only call an atom untested that in fact came
      # out both ways (under a LIMIT that hid the difference, say), never
      # the other way round. An atom with_value can't replace (a USING
      # column, a NATURAL JOIN marker, a deparse it can't trust) is
      # untested, and so is every atom of a query Reach.worst_case? names,
      # with nothing checked.
      #
      # A direction is checked only until it's seen: on each of the first
      # FIRST worlds observed, then on FIRST worlds in each doubling of the
      # count after that, so a direction no world shows costs a few hundred
      # queries in a long search, never one per trial.
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

        def initialize(atoms, original)
          @atoms = atoms
          @pending = Reach.worst_case?(original) ? {} : loosened(PgQuery.parse(original))
          @seen = Hash.new { |h, k| h[k] = Set.new }
          @observed = 0
        end

        # Checks each pending direction on the world session's last trial
        # compared, if this observation is due.
        def observe(session)
          return if @pending.empty? || !due?(@observed += 1)

          @pending.select! do |(index, value), sql|
            next true unless session.differs?(sql)

            @seen[index] << value
            false
          end
        end

        def result
          untested = @atoms.each_index.reject { @seen[it].size == 2 }
          Result.new(atoms: @atoms.size, untested_atoms: untested, untested_shapes: untested.map { @atoms[it].shape },
                     untested_paths: untested.map { @atoms[it].path })
        end

        private

        def due?(count)
          return true if count <= FIRST

          spacing = 2**Math.log2(count / FIRST).floor
          (count % spacing).zero?
        end

        # Each replaceable atom's two loosened queries, by [index, value].
        def loosened(parse)
          @atoms.each_with_index.with_object({}) do |(atom, index), pending|
            [true, false].each { pending[[index, it]] = PredicateAtoms.with_value(parse, atom, it) }
          rescue PredicateAtoms::Error, Deparse::Error
            next
          end
        end
      end
    end
  end
end
