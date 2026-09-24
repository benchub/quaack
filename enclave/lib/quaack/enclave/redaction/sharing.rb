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
      # shared or not, so the search doesn't go into subqueries. But a key
      # that's a whole subquery shares its constants with its copies'.
      # A key written by position or alias stands for its select-list entry
      # (see Keys).
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
          targets = stmt.target_list.map(&:res_target)
          sort_keys = Keys.resolved(sort_keys(stmt.sort_clause), targets)
          pair(Keys.resolved(stmt.group_clause, targets),
               [*stmt.target_list, stmt.having_clause, *sort_keys, *stmt.window_clause])
          distinct(stmt, targets, sort_keys)
        end

        # DISTINCT ON's list holds its expressions. A plain DISTINCT's holds
        # one empty node.
        def distinct(stmt, targets, sort_keys)
          on = stmt.distinct_clause.reject { it.node.nil? }
          if on.any? then pair(Keys.resolved(on, targets), sort_keys)
          elsif stmt.distinct_clause.any? then pair(sort_keys, stmt.target_list)
          end
        end

        def sort_keys(clause) = clause.filter_map { it.sort_by&.node }

        def aggregate(call) = pair(sort_keys(call.agg_order), call.args)

        # Joins every key with every node under the regions that's the same
        # expression. Only a node with as many nodes under it as a key can be
        # the same, so only those are compared, and a deep expression costs
        # one form per key rather than one for every node under it.
        def pair(keys, regions)
          by_form = keys.group_by { form(it) }
          return if by_form.empty?

          sizes = keys.to_set { size(it) }
          regions.compact.each do |region|
            sized(region) { |node, size| by_form[form(node)]&.each { join(it, node) } if sizes.include?(size) }
          end
        end

        # Yields every Node under this one, and it, with the number of nodes
        # under it, and gives that number for this one.
        def sized(node, &)
          size = 1 + children(node.inner).sum { sized(it, &) }
          yield node, size
          size
        end

        def size(node) = sized(node) { nil }

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

        # The Nodes right under a message, but only a subquery's test
        # expression, not the subquery.
        def children(message)
          return [message.testexpr].compact if message.is_a?(PgQuery::SubLink)

          inner_nodes(message)
        end

        # The Nodes right under a message, through any messages that aren't
        # Nodes, but not in a type's name.
        def inner_nodes(message)
          return [] if message.nil? || message.is_a?(PgQuery::TypeName)

          values(message).flat_map { |value| value.is_a?(PgQuery::Node) ? [value] : inner_nodes(value) }
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

        # The locations of the placeholders under a node, in tree order. A
        # key that's a whole subquery holds the subquery's constants too.
        def constants(node)
          found = []
          walk = node.sub_link ? method(:everything) : method(:nodes)
          walk.call(node) { |n| found << n.a_const.location if n.a_const && @found.key?(n.a_const.location) }
          found
        end

        # Every Node under this one, and it, subqueries included.
        def everything(node, &)
          yield node
          inner_nodes(node.inner).each { everything(it, &) }
        end

        def union(one, other)
          one = representative(one)
          other = representative(other)
          return if one == other

          first, last = [one, other].minmax
          @parent[last] = first
        end
      end

      # A GROUP BY, DISTINCT ON, or ORDER BY key written as a select-list
      # entry's position, such as GROUP BY 1, or its name, such as GROUP BY
      # k for AS k, stands for that entry's expression. Postgres takes a
      # GROUP BY name as a FROM column first, if there's one of that name.
      # Reading it as the entry anyway only shares more constants, and those
      # always hold equal values, so the query means the same.
      module Keys
        module_function

        # targets are the select list's ResTargets.
        def resolved(keys, targets)
          keys.map { |key| position(key, targets) || named(key, targets) || key }
        end

        def position(key, targets)
          number = key.a_const.ival.ival if key.a_const&.val == :ival
          targets[number - 1]&.val if number&.positive?
        end

        def named(key, targets)
          name = name(key)
          targets.find { |target| target.name == name }&.val if name
        end

        # The name of a key that's one unqualified column, or nil.
        def name(key)
          fields = key.column_ref&.fields
          fields.first.string&.sval if fields&.size == 1
        end
      end

      private_constant :Sharing, :Keys
    end
  end
end
