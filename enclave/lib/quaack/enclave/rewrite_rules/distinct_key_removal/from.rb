# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class DistinctKeyRemoval
        # One JOIN of a From: the joined table's RangeVar, the conditions
        # its ON ANDs, and the RangeVars of the tables before it, which are
        # all of this FROM that the ON can read.
        Join = Data.define(:table, :conditions, :before)

        # The joins a From takes, neither of which can fill the first table
        # with NULLs.
        JOIN_TYPES = %i[JOIN_INNER JOIN_LEFT].freeze

        # A FROM the rule can read: root, the RangeVar of its first table,
        # and joins, a Join for each JOIN after it, in order.
        #
        # From.read gives it, or nil unless the FROM is one item: a table,
        # then any number of inner or left JOINs, each to one table, with
        # no alias, which could rename the columns, nested only on the
        # left, as root JOIN a ON ... LEFT JOIN b ON ... nests. Every table
        # is a plain table (Tree.plain_table?) under a name of its own. So
        # the first table is on no join's nullable side, and each row of it
        # gives at most one row of the FROM once every join matches at
        # most one row. A NATURAL or USING join has no ON, so no Join of it
        # pairs a key (see Keys.join).
        From = Data.define(:root, :joins) do
          def self.read(from_clause)
            chain = chain(from_clause.first) if from_clause.size == 1
            return unless chain

            root, *joins = chain
            tables = [root, *joins.map { it.rarg.range_var }]
            build(tables, joins) if tables.all? { Tree.plain_table?(it) } && named_apart?(tables)
          end

          def self.build(tables, joins)
            new(root: tables.first, joins: joins.each_with_index.map do |join, i|
              Join.new(table: tables[i + 1], conditions: Tree.conjuncts(join.quals), before: tables.first(i + 1))
            end)
          end

          # The first table's RangeVar, then each JoinExpr in order, or nil.
          def self.chain(node)
            case node.node
            when :range_var then [node.range_var]
            when :join_expr
              left = chain(node.join_expr.larg) if plain?(node.join_expr)
              [*left, node.join_expr] if left
            end
          end

          def self.plain?(join)
            JOIN_TYPES.include?(join.jointype) && join.alias.nil? && join.rarg.node == :range_var
          end

          def self.named_apart?(tables) = tables.map { Tree.refname(it) }.uniq.size == tables.size
        end
      end
    end
  end
end
