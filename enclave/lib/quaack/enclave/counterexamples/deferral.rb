# frozen_string_literal: true

require "pg_query"
require_relative "../arena_fixture"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Counterexamples
      # An accepted insert, ready to load when its table has columns the
      # load order cuts (Scenarios::Topology#cut_columns). A value the insert
      # gives such a column, other than NULL or DEFAULT, is evaluated in
      # arena, replaced by NULL in the insert, and set by a deferred UPDATE
      # once every insert has loaded (ArenaRunner::DeferredInsert). That
      # leaves the row as the LLM wrote it. An insert that sets no cut
      # column stays its SQL.
      module Deferral
        module_function

        def insert(conn, accepted, cut)
          positions = cut_positions(accepted.parse.tree, cut)
          return accepted.sql if positions.empty?

          tree = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(accepted.parse.tree))
          updates = values_lists(tree).map { |list| defer(conn, list.list.items, positions) }
          ArenaRunner::DeferredInsert.new(sql: PgQuery.deparse(tree), updates:)
        end

        def values_lists(tree) = tree.stmts[0].stmt.insert_stmt.select_stmt.select_stmt.values_lists

        # Each cut column the insert names, with its place in a VALUES row.
        def cut_positions(tree, cut)
          names = tree.stmts[0].stmt.insert_stmt.cols.map { |c| c.res_target.name }
          names.each_with_index.filter_map { |name, i| [name, i] if cut.include?(name) }
        end

        # The row's deferred values, each item replaced by NULL. A DEFAULT
        # stays.
        def defer(conn, items, positions)
          positions.each_with_object({}) do |(name, i), set|
            next if items[i].set_to_default

            value = text(conn, items[i])
            items[i] = PgQuery::Node.new(a_const: PgQuery::A_Const.new(isnull: true))
            set[name] = value unless value.nil?
          end
        end

        def text(conn, value)
          conn.exec("SELECT (#{ValuePools::Sides.select_of(value).delete_prefix("SELECT ")})::text").getvalue(0, 0)
        end
      end
    end
  end
end
