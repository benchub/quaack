# frozen_string_literal: true

module Quaack
  module Enclave
    module ResultComparison
      # The precise check for an original whose LIMIT or OFFSET cuts a tie
      # group, so its T and T' runs (see result_comparison.rb) keep
      # different rows. Pure: it works on rows already fetched, through two
      # lambdas. key gives a row's identity, for rows that are the same to
      # the comparison. contained.(big, small) says whether small's rows
      # can each be paired with a row of big's of their own.
      #
      # A query's full result, run without its LIMIT and OFFSET with the
      # tiebreaker ascending and then descending, splits into groups: the
      # tie groups of the query's own ORDER BY. A boundary falls wherever
      # the two runs' prefixes hold the same rows, and each group must come
      # back exactly reversed in the descending run, or there's no Layout.
      # A boundary between two tie groups always holds the same rows on
      # both sides. One inside a group can only fall between rows that are
      # all the same, which can't matter. The window is the part of the
      # full result the cut keeps.
      module CutTies
        # rows are the full result in ascending order, keys their keys,
        # blocks a Range of positions for each group, and window the Range
        # of positions the cut keeps.
        Layout = Data.define(:rows, :keys, :blocks, :window)

        module_function

        # Whether the precise check must run instead of matching the
        # candidate's T and T' runs row for row: when the original's T and
        # T' runs keep different rows (uncut is false), or when it keeps
        # some rows (kept_rows) with a LIMIT and an OFFSET, whose rows can
        # sit inside a tie group and come out the same both ways.
        def needed?(shape, uncut:, kept_rows:) = !uncut || (shape.cut_both_ends? && kept_rows)

        # The whole check, as [rule, fields]: rule is nil for a match, or
        # :row_count, :value, or :unsupported_order, and fields holds a
        # Verdict's expected_rows, actual_rows, and row, as far as known.
        # shapes are the original's and the candidate's, and original_cut
        # the original's two cut runs. source runs queries and compares
        # rows: fetch(shape, limited:) runs a query both ways, with its
        # LIMIT and OFFSET or without them, and gives the two runs' rows,
        # and it answers key(row), contained?(big, small), and
        # all_columns?, whether every column is in the tiebreaker. It
        # refuses unless all_columns?, and for DISTINCT ON, whose picks the
        # full runs can't show.
        def check(shapes, original_cut, source)
          return REFUSED unless source.all_columns? && shapes.none?(&:distinct_on?)

          original = layout_of(shapes.first, original_cut, source)
          return REFUSED unless original

          candidate_check(original, shapes.last, source.fetch(shapes.last, limited: true), source)
        end

        def candidate_check(original, shape, cut, source)
          mismatch = cut_mismatch(original, cut, source)
          return mismatch if mismatch

          candidate = layout_of(shape, cut, source)
          return REFUSED unless candidate && covers?(original, candidate, contained: source.method(:contained?))

          [nil, { expected_rows: original.window.size, actual_rows: original.window.size }]
        end

        def layout_of(shape, cut, source)
          layout(full: source.fetch(shape, limited: false), cut:, offset: shape.offset, key: source.method(:key))
        end

        REFUSED = [:unsupported_order, {}.freeze].freeze

        # A row_count or value mismatch for the candidate's cut runs, or nil.
        def cut_mismatch(original, cut, source)
          cut.each do |rows|
            counts = { expected_rows: original.window.size, actual_rows: rows.size }
            return [:row_count, counts] if rows.size != original.window.size

            row = wrong_row(original, rows, contained: source.method(:contained?))
            return [:value, { **counts, row: }] if row
          end
          nil
        end

        # contained for rows that are their own keys, such as hashes.
        def tallied?(big, small)
          tally = big.tally
          small.tally.all? { |row, count| tally.fetch(row, 0) >= count }
        end

        # full and cut are each [ascending, descending] rows. offset is
        # the cut's OFFSET when it's known, or nil, and then it's the only
        # place both cut runs fit, if there's just one. nil when there's no
        # Layout.
        def layout(full:, cut:, offset:, key:)
          full_keys = full.map { |rows| rows.map(&key) }
          cut_keys = cut.map { |rows| rows.map(&key) }
          blocks = blocks(*full_keys)
          window = window(full_keys, cut_keys, offset) if blocks
          Layout.new(rows: full.first, keys: full_keys.first, blocks:, window:) if window
        end

        def blocks(ascending, descending)
          return unless ascending.size == descending.size

          found = boundaries(ascending, descending)
          return unless found

          blocks = found.each_cons(2).map { |first, last| first...last }
          blocks if blocks.all? { |block| descending[block] == ascending[block].reverse }
        end

        # Positions where both runs' prefixes hold the same rows, from 0 to
        # the end, or nil when the whole runs don't.
        def boundaries(ascending, descending)
          counts = Hash.new(0)
          found = [0]
          ascending.zip(descending).each_with_index do |(up, down), position|
            [[up, 1], [down, -1]].each do |row, step|
              counts[row] += step
              counts.delete(row) if counts[row].zero?
            end
            found << (position + 1) if counts.empty?
          end
          found if found.last == ascending.size
        end

        def window(full_keys, cut_keys, offset)
          size = cut_keys.first.size
          return unless cut_keys.last.size == size

          starts = offset ? [offset] : (0..(full_keys.first.size - size))
          fits = starts.select { |start| fits?(full_keys, cut_keys, start, size) }
          fits.first...(fits.first + size) if fits.size == 1
        end

        def fits?(full_keys, cut_keys, start, size)
          start + size <= full_keys.first.size && full_keys.zip(cut_keys).all? { |full, cut| full[start, size] == cut }
        end

        # The index of the first row in run_rows, a cut run of the same
        # size as original's window, that the original can't return there:
        # where the rows at a group's positions in the window aren't drawn
        # from that group. nil when there's none.
        def wrong_row(original, run_rows, contained:)
          start = original.window.begin
          original.blocks.each do |block|
            kept = overlap(block, original.window).map { |position| position - start }
            next if kept.none? || contained.call(original.rows[block], run_rows.values_at(*kept))

            return kept.first
          end
          nil
        end

        # Whether every row the candidate's cut could keep, however its ties
        # break, is one the original's could keep there too. A candidate
        # group of one lends its row to the original's group at its place
        # in the window. A larger one can keep any of its rows anywhere it
        # meets the window, so it lends all its rows to each of the
        # original's groups it meets there. Each original group must hold
        # all the rows lent it.
        def covers?(original, candidate, contained:)
          return false unless original.window.size == candidate.window.size

          shift = original.window.begin - candidate.window.begin
          lent = lent_rows(original, candidate, shift)
          lent.all? { |index, rows| contained.call(original.rows[original.blocks[index]], rows) }
        end

        def lent_rows(original, candidate, shift)
          candidate.blocks.each_with_object(Hash.new { |hash, index| hash[index] = [] }) do |block, lent|
            groups_met(original, candidate, block, shift).each { |index| lent[index].concat(candidate.rows[block]) }
          end
        end

        # The original's groups that a candidate group meets in the window.
        def groups_met(original, candidate, block, shift)
          overlap(block, candidate.window).map { |position| group_at(original, position + shift) }.uniq
        end

        def group_at(layout, position) = layout.blocks.index { |block| block.cover?(position) }

        def overlap(block, window) = ([block.begin, window.begin].max...[block.end, window.end].min).to_a
      end
    end
  end
end
