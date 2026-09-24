# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"

module Quaack
  module Enclave
    module Redaction
      # Which constants must share one placeholder (see "Expressions that
      # must match" in Redaction). Postgres requires some pairs of
      # expressions to be the same expression, constants included, and
      # compares them after binding, so $1 and $2 of the same value don't
      # count as the same. Tried on Postgres 18, these pairs fail to
      # prepare unless they share:
      # - A GROUP BY expression and the same expression in the select list
      #   (a window's too), HAVING, or ORDER BY (42803).
      # - DISTINCT ON's expressions and ORDER BY's (42P10).
      # - SELECT DISTINCT's list and ORDER BY's (42P10).
      # - An aggregate's DISTINCT arguments and its ORDER BY (42P10).
      # A subquery can't use a grouped expression of the query outside it,
      # shared or not, so the search doesn't go into subqueries.
      #
      # Two expressions are the same when their parse trees match with the
      # locations cleared, so their constants are equal too, in the same
      # places. Each such pair's constants are joined, in order. Nothing
      # else shares, even two equal expressions in the select list.
      class Sharing
        # found maps each constant's location to what the query walk
        # recorded for it, and says which constants are placeholders.
        def initialize(found)
          @found = found
          @parent = {}
        end

        # Joins the constants of every matching pair the message holds, if
        # it's a SELECT or a function call.
        def note(message)
          case message
          when PgQuery::SelectStmt then select(message)
          when PgQuery::FuncCall then aggregate(message) if message.agg_distinct
          end
        end

        # The location of the constant whose placeholder this one uses.
        def representative(location)
          location = @parent[location] while @parent.key?(location)
          location
        end

        private

        def select(stmt)
          sort_keys = sort_keys(stmt.sort_clause)
          pair(stmt.group_clause, [*stmt.target_list, stmt.having_clause, *sort_keys, *stmt.window_clause])
          distinct(stmt, sort_keys)
        end

        # DISTINCT ON's list holds its expressions. A plain DISTINCT's holds
        # one empty node.
        def distinct(stmt, sort_keys)
          on = stmt.distinct_clause.reject { it.node.nil? }
          if on.any? then pair(on, sort_keys)
          elsif stmt.distinct_clause.any? then pair(sort_keys, stmt.target_list)
          end
        end

        def sort_keys(clause) = clause.filter_map { it.sort_by&.node }

        def aggregate(call) = pair(sort_keys(call.agg_order), call.args)

        # Joins each key with every node under the regions that's the same
        # expression.
        def pair(keys, regions)
          by_form = keys.to_h { |key| [form(key), key] }
          return if by_form.empty?

          regions.compact.each { |region| nodes(region) { |node| by_form[form(node)]&.then { join(it, node) } } }
        end

        # The expression with its locations cleared, as bytes.
        def form(node)
          copy = PgQuery::Node.decode(PgQuery::Node.encode(node, recursion_limit: Deparse::DEPTH),
                                      recursion_limit: Deparse::DEPTH)
          Deparse.clear_locations(copy)
          PgQuery::Node.encode(copy, recursion_limit: Deparse::DEPTH)
        end

        # Every Node under this one, and it, but not inside a subquery.
        def nodes(node, &)
          yield node
          children(node.inner).each { |child| nodes(child, &) }
        end

        def children(message)
          return [] if message.nil? || message.is_a?(PgQuery::TypeName)
          return [message.testexpr].compact if message.is_a?(PgQuery::SubLink)

          values(message).flat_map { |value| value.is_a?(PgQuery::Node) ? [value] : children(value) }
        end

        # The messages in a message's fields.
        def values(message)
          message.class.descriptor.select { it.type == :message }.flat_map do |field|
            value = field.get(message)
            field.label == :repeated ? value.to_a : [value].compact
          end
        end

        def join(key, node)
          constants(key).zip(constants(node)).each { |one, other| union(one, other) }
        end

        # The locations of the placeholders under a node, in tree order.
        def constants(node)
          found = []
          nodes(node) { |n| found << n.a_const.location if n.a_const && @found.key?(n.a_const.location) }
          found
        end

        def union(one, other)
          one = representative(one)
          other = representative(other)
          return if one == other

          first, last = [one, other].minmax
          @parent[last] = first
        end
      end

      private_constant :Sharing
    end
  end
end
