# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Mixed into View: the warning for the query's tables that sit in
      # another tablespace on the run server than in production (DESIGN.md's
      # run-server checks). The payload names the tables only, never a
      # tablespace, since a tablespace's name is production configuration.
      module TablespaceMoves
        # The verdict's caveat, or nil when every table sits where it does in production.
        def tablespace_moves
          moves = @payload.fetch("tablespace_moves", nil) or return
          return if moves.empty?

          "#{Format.number(moves.size)} of the query's tables #{moves.size == 1 ? "sits" : "sit"} in a different " \
            "tablespace on the run server than in production: #{moved_tables(moves)}. QUAACK's block counts may " \
            "not match production's."
        end

        # The ranking section's note: which tables, what it may change, and how to check.
        def tablespace_moves_note
          moves = @payload.fetch("tablespace_moves", nil) or return
          return if moves.empty?

          "These tables, or their TOAST tables or indices, sit in a different tablespace on the run server than " \
            "in production: #{moved_tables(moves)}. A tablespace on other storage can change the plans Postgres " \
            "picks and the blocks it reads, so the counts below may not match what production would read. To " \
            "check, compare pg_class.reltablespace for these tables, their TOAST tables and their indices on " \
            "both servers. QUAACK went on, since the tablespaces themselves match."
        end

        def moved_tables(moves) = moves.map { Format.sql_span(it) }.join(", ")
      end
    end
  end
end
