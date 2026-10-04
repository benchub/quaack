# frozen_string_literal: true

require "pg_query"
require_relative "../arena_fixture"

module Quaack
  module Enclave
    module Counterexamples
      # An accepted insert, ready to load when its table has columns the
      # load order cuts (Scenarios::Topology#cut_columns). A value the insert
      # gives such a column, other than NULL or DEFAULT, is replaced by NULL
      # in the insert, and its text, as Evaluated read it in arena, is set
      # by a deferred UPDATE once every insert has loaded
      # (ArenaRunner::DeferredInsert). That leaves the row as the LLM wrote
      # it. An insert that sets no cut column stays its SQL.
      module Deferral
        module_function

        # evaluated is an Evaluated insert.
        def insert(evaluated, cut)
          accepted = evaluated.insert
          positions = cut_positions(accepted.parse.tree, cut)
          return accepted.sql if positions.empty?

          tree = PgQuery::ParseResult.decode(PgQuery::ParseResult.encode(accepted.parse.tree))
          updates = updates(tree, evaluated.rows, positions)
          ArenaRunner::DeferredInsert.new(sql: PgQuery.deparse(tree), updates:)
        end

        # Each row's deferred values, with NULL put in their place in tree.
        def updates(tree, rows, positions)
          values_lists(tree).zip(rows).map { |list, row| defer(list.list.items, row, positions) }
        end

        def values_lists(tree) = tree.stmts[0].stmt.insert_stmt.select_stmt.select_stmt.values_lists

        # Each cut column the insert names, with its place in a VALUES row.
        def cut_positions(tree, cut)
          names = tree.stmts[0].stmt.insert_stmt.cols.map { |c| c.res_target.name }
          names.each_with_index.filter_map { |name, i| [name, i] if cut.include?(name) }
        end

        # The row's deferred values, each item replaced by NULL. A DEFAULT
        # stays.
        def defer(items, row, positions)
          positions.each_with_object({}) do |(name, i), set|
            next if items[i].set_to_default

            items[i] = PgQuery::Node.new(a_const: PgQuery::A_Const.new(isnull: true))
            set[name] = row[name] unless row[name].nil?
          end
        end
      end
    end
  end
end
