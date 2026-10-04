# frozen_string_literal: true

require "pg"
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
      # A value Postgres can't evaluate, such as a bad cast, refuses the
      # insert with bad_value. Postgres's message can quote the value, so
      # the Refusal holds only the rule, and no cause.
      Evaluated = Data.define(:insert, :rows) do
        def self.of(conn, insert)
          stmt = insert.parse.tree.stmts[0].stmt.insert_stmt
          new(insert:, rows: stmt.select_stmt.select_stmt.values_lists.map { row(conn, stmt.cols, it) })
        rescue PG::Error
          raise Refusal, "bad_value", cause: nil
        end

        def self.row(conn, cols, list) = cols.map { it.res_target.name }.zip(texts(conn, list)).to_h

        def self.texts(conn, list) = list.list.items.map { text(conn, it) }

        def self.text(conn, value)
          return :default if value.set_to_default

          conn.exec("SELECT (#{ValuePools::Sides.select_of(value).delete_prefix("SELECT ")})::text").getvalue(0, 0)
        end

        def table = insert.table

        def inspect = "#<data #{self.class} insert=<redacted> rows=<redacted>>"

        alias_method :to_s, :inspect
      end
    end
  end
end
