# frozen_string_literal: true

require "pg"
require_relative "../redaction"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Counterexamples
      # An accepted insert (InsertCheck::Accepted), and its VALUES rows,
      # each as { column => text }, with :default for DEFAULT and nil for
      # NULL. Each value is evaluated in arena once, here, and ParentRows and
      # Deferral read the texts. A value passed the inbound check, so it's
      # immutable.
      #
      # A value Postgres can't evaluate refuses the insert with bad_value.
      # That's an error of SQLSTATE class 22 (data exception, such as a bad
      # cast), 23 (integrity constraint violation, which a SELECT of a value
      # can raise only from a domain's CHECK or NOT NULL), or 42 (the
      # value's expression doesn't type-check, such as lower(1)), except
      # 42501, a permission error. P0001 (a function raised) and 54000
      # (a program limit) count too. Each comes
      # from the LLM's insert, not the arena. Postgres's message can quote
      # the value, so the Refusal holds only the rule, and no cause. Any
      # other error, such as a statement timeout or a dropped connection,
      # goes up as a Redaction::Error with only its SQLSTATE, and the step
      # reports it by rule and SQLSTATE (ErrorFilter).
      Evaluated = Data.define(:insert, :rows) do
        def self.of(conn, insert)
          stmt = insert.parse.tree.stmts[0].stmt.insert_stmt
          new(insert:, rows: stmt.select_stmt.select_stmt.values_lists.map { row(conn, stmt.cols, it) })
        rescue PG::Error => e
          raise_for(e.result&.error_field(PG::PG_DIAG_SQLSTATE))
        end

        # Postgres's message can quote the value, so neither error carries
        # it, or a cause.
        def self.raise_for(sqlstate)
          raise Refusal, "bad_value", cause: nil if bad_value?(sqlstate)

          raise Redaction::Error.new(:internal_error, sqlstate), cause: nil
        end

        # Whether sqlstate says the value is at fault: a data exception
        # (class 22), an integrity violation (23), a type error in its
        # expression (42, but not 42501, a permission error), or an error
        # its own function or trigger raised (P0001) or a program limit it
        # hit (54000).
        def self.bad_value?(sqlstate)
          sqlstate = sqlstate.to_s
          return false if sqlstate == "42501"

          %w[22 23 42].include?(sqlstate[0, 2]) || %w[P0001 54000].include?(sqlstate)
        end

        def self.row(conn, cols, list) = cols.map { it.res_target.name }.zip(texts(conn, list)).to_h

        def self.texts(conn, list) = list.list.items.map { text(conn, it) }

        def self.text(conn, value)
          return :default if value.set_to_default

          conn.exec("SELECT (#{ValuePools::Sides.select_of(value).delete_prefix("SELECT ")})::pg_catalog.text")
              .getvalue(0, 0)
        end

        def table = insert.table

        def inspect = "#<data #{self.class} insert=<redacted> rows=<redacted>>"

        alias_method :to_s, :inspect
      end
    end
  end
end
