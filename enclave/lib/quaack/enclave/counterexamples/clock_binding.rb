# frozen_string_literal: true

require "pg_query"
require_relative "../clock_literals"
require_relative "../insert_check"
require_relative "../insert_clock_words"

module Quaack
  module Enclave
    module Counterexamples
      # Where a counterexample's $n is bound to the clock anchor's value
      # rather than its literal: the literal is a clock word ('now',
      # 'today', 'tomorrow', or 'yesterday', as ClockLiterals::WORD matches
      # it), and InsertClockWords would find it reads the clock there. The
      # word becomes the anchor's value written out in the session's
      # TimeZone, so a date, time, or timestamp reads it as Postgres would
      # have read the word at the anchor's instant.
      #
      #   ClockBinding.anchored(conn, sql, placeholder_map, tables, settings)
      #   # => { 41 => "2024-03-10" }, the text for each $n by location
      #
      # The texts hold real values, and stay in the enclave.
      module ClockBinding
        module_function

        def anchored(conn, sql, placeholder_map, tables, settings)
          words = clock_words(placeholder_map)
          return {} if words.empty?

          numbers = clock_params(conn, sql, words, tables, settings)
          return {} if numbers.empty?

          texts = anchor_texts(conn)
          numbers.transform_values { texts.fetch(words.fetch(it)) }
        end

        # InsertClockWords.clock_params on the unbound insert; none if the
        # insert would be refused before its clock_literal rule.
        def clock_params(conn, sql, words, tables, settings)
          stmt = InsertCheck.insert_stmt(InsertCheck.parse(sql))
          types = InsertCheck.columns!(stmt.cols, InsertCheck.table!(stmt.relation, tables), conn)
          InsertClockWords.clock_params(stmt.cols, InsertCheck.rows!(stmt), types, settings, conn) { words[it] }
        rescue InsertCheck::Error, InsertClockWords::Error
          {}
        end

        def clock_words(placeholder_map)
          placeholder_map.to_h.filter_map do |number, entry|
            match = ClockLiterals::WORD.match(entry["value"].to_s)
            [Integer(number.delete_prefix("$"), 10), match[1].downcase] if match
          end.to_h
        end

        # 'now', 'today', 'yesterday', and 'tomorrow', from the anchor.
        ANCHOR_TEXTS_SQL = <<~SQL
          SELECT pg_catalog.to_char(a, 'YYYY-MM-DD HH24:MI:SS.USTZH:TZM'),
                 pg_catalog.to_char(d, 'YYYY-MM-DD'),
                 pg_catalog.to_char(d OPERATOR(pg_catalog.-) 1, 'YYYY-MM-DD'),
                 pg_catalog.to_char(d OPERATOR(pg_catalog.+) 1, 'YYYY-MM-DD')
          FROM quaack.clock_anchor() a, pg_catalog.date(a) d
        SQL

        def anchor_texts(conn) = %w[now today yesterday tomorrow].zip(conn.exec(ANCHOR_TEXTS_SQL).values.first).to_h
      end
    end
  end
end
