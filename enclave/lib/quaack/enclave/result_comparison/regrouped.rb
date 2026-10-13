# frozen_string_literal: true

require_relative "cut_ties"

module Quaack
  module Enclave
    module ResultComparison
      # The candidate's check for an original whose T and T' runs (see
      # result_comparison.rb) keep the same rows, so its LIMIT and OFFSET
      # cut no tie group. The candidate's T and T' runs must match the
      # original's row for row, or, when they don't, hold each of the
      # original's tie groups at its place, in any order. Any order of a tie
      # group is an answer the original could give, so a candidate that
      # orders the original's ties its own way, such as ORDER BY a, id for
      # ORDER BY a, still matches. Fixture-compare and result-comparison
      # both use it, on rows and on row hashes.
      #
      # Why the group check is enough. The original's answers are exactly
      # its tie groups in order, each in any order of its own. A
      # candidate's answers are its own tie groups in order, each in any
      # order, and its T run puts each group's rows in ascending tiebreaker
      # order, its T' run in descending. A candidate group that lies inside
      # one of the original's groups can only move its rows within that
      # group. One that reaches past the end of an original group by k of
      # its n rows puts its smallest k rows there in T and its largest k in
      # T', and both runs fit only when those are the same rows, which
      # makes all n the same. Then any order of it is the same answer. A
      # DISTINCT ON picks the smallest of its choices in T and the largest
      # in T', and both fit only when each pick is the same both ways,
      # which makes all its choices the same. So every answer the
      # candidate could give fits too.
      #
      # The groups come from CutTies.layout over each query's two runs.
      # CutTies.covers? needs no check here: in the candidate's layout, no
      # group can reach past the end of one of the original's once both
      # runs fit, since its first k rows in T and in T' would be the same
      # rows, which is a boundary.
      module Regrouped
        module_function

        # :match, :unsupported_order, or the row-for-row mismatch. source
        # gives the candidate's runs: run(descending), mismatch(original,
        # run) for the row-for-row mismatch or nil, rows(run), key(row), and
        # contained?(big, small) as for CutTies. The T' run runs only when
        # T matches row for row or fits the groups.
        def tiebroken(originals, source)
          ascending = source.run(false)
          found = source.mismatch(originals.first, ascending)
          descending = source.run(true) unless found
          found ||= source.mismatch(originals.last, descending)
          return :match unless found

          regrouped(originals, ascending, source) { descending || source.run(true) } || found
        end

        # check over the source's rows, yielding for the candidate's T' run.
        def regrouped(originals, ascending, source)
          check(originals.map { source.rows(it) }, source.rows(ascending), key: source.method(:key),
                                                                           contained: source.method(:contained?)) do
            source.rows(yield)
          end
        end

        # Whether a candidate's runs, which don't match the original's row
        # for row, hold each of the original's tie groups at its place.
        # originals are the original's [ascending, descending] rows, and
        # ascending the candidate's T run. It yields for the candidate's T'
        # run only once its T run fits. :match when both fit, and
        # :unsupported_order when they do but the candidate's runs don't
        # split into reversed groups, so they can't show its ties, such as
        # for a volatile sort key. nil when they don't fit, or the
        # original's runs don't split into reversed groups.
        def check(originals, ascending, key:, contained:)
          original = whole(originals, key)
          return unless original && fits?(original, ascending, contained)

          descending = yield
          return unless fits?(original, descending, contained)

          whole([ascending, descending], key) ? :match : :unsupported_order
        end

        # The Layout of two whole runs.
        def whole(runs, key) = CutTies.layout(full: runs, cut: runs, offset: 0, key:)

        # Whether rows, a whole run, hold each of original's groups at its
        # place.
        def fits?(original, rows, contained)
          rows.size == original.window.size && !CutTies.wrong_row(original, rows, contained:)
        end
      end
    end
  end
end
