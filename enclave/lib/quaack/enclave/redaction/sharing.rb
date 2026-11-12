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
      # that holds a subquery, whole or inside a larger expression, shares
      # the subquery's constants with its copies'.
      # A key written by position or alias stands for its select-list entry
      # (see Keys).
      #
      # Two expressions are the same when their parse trees match with the
      # locations cleared and each column reference cut to its column's
      # name, so their constants are equal too, in the same places. Each
      # such pair's constants are joined, in order. Postgres takes two
      # expressions written differently around their constants as the same,
      # such as o.status || '-x' and status || '-x', so the column's name is
      # enough. A constant outside every copy of a key doesn't share with
      # it, even one written the same way (task 20261111-4). Constants
      # equal in value but written differently, such as 5 and '5'::integer,
      # don't share. Nothing else shares, even two equal expressions in the
      # select list.
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
          relations = Relations.of(stmt.from_clause)
          targets = stmt.target_list.map(&:res_target)
          sort_keys = Keys.resolved(sort_keys(stmt.sort_clause), targets)
          pair(Keys.resolved(stmt.group_clause, targets),
               [*stmt.target_list, stmt.having_clause, *sort_keys, *stmt.window_clause], relations)
          distinct(stmt, targets, sort_keys, relations)
        end

        # DISTINCT ON's list holds its expressions. A plain DISTINCT's holds
        # one empty node.
        def distinct(stmt, targets, sort_keys, relations)
          on = stmt.distinct_clause.reject { it.node.nil? }
          if on.any? then pair(Keys.resolved(on, targets), sort_keys, relations)
          elsif stmt.distinct_clause.any? then pair(sort_keys, stmt.target_list, relations)
          end
        end

        def sort_keys(clause) = clause.filter_map { it.sort_by&.node }

        # An aggregate's note doesn't say which FROM list it's in, so its
        # column references match whatever relation they name.
        def aggregate(call)
          pair(sort_keys(call.agg_order), call.args, {})
        end

        # Joins every key with every node under the regions that's the same
        # expression. Only a node with as many nodes under it as a key can be
        # the same, so only those are compared, and a deep expression costs
        # one form per key rather than one for every node under it.
        def pair(keys, regions, relations)
          by_form = keys.group_by { form(it) }
          return if by_form.empty?

          sizes = keys.to_set { size(it) }
          regions.compact.each do |region|
            sized(region) do |node, size|
              next unless sizes.include?(size)

              by_form[form(node)]&.each { join(it, node) if same_relations?(it, node, relations) }
            end
          end
        end

        # Whether each column reference under one node resolves to the same
        # relation as the one in its place under the other. Their forms
        # match, so they line up. A reference whose relation isn't known,
        # such as an unqualified one, matches any.
        def same_relations?(one, other, relations)
          pairs = relations_under(one, relations).zip(relations_under(other, relations))
          pairs.all? { |a, b| a.nil? || b.nil? || a == b }
        end

        def relations_under(node, relations)
          [].tap { |found| everything(node) { |n| found << Relations.named(relations, n.column_ref) if n.column_ref } }
        end

        # Yields every Node under this one, and it, with the number of nodes
        # under it, and gives that number for this one.
        def sized(node, &)
          size = 1 + children(node.inner).sum { sized(it, &) }
          yield node, size
          size
        end

        def size(node) = sized(node) { nil }

        # The expression with its locations cleared and each column
        # reference cut to its last field, as bytes.
        def form(node)
          copy = PgQuery::Node.decode(PgQuery::Node.encode(node, recursion_limit: Deparse::DEPTH),
                                      recursion_limit: Deparse::DEPTH)
          Deparse.clear_locations(copy)
          everything(copy) { |n| n.column_ref&.fields&.then { it.replace([it.last]) } }
          PgQuery::Node.encode(copy, recursion_limit: Deparse::DEPTH)
        end

        # The Nodes right under a message, but only a subquery's test
        # expression, not the subquery, and none under a column reference,
        # which form cuts to one name, so o.status and status count alike.
        def children(message)
          return [message.testexpr].compact if message.is_a?(PgQuery::SubLink)
          return [] if message.is_a?(PgQuery::ColumnRef)

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

        # The locations of the placeholders under a node, in tree order,
        # subqueries included: a pair's forms match through its subqueries
        # too, so their constants line up there as well.
        def constants(node)
          found = []
          everything(node) { |n| found << n.a_const.location if n.a_const && @found.key?(n.a_const.location) }
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

      # The relations a FROM list names, by the name a column reference
      # qualifies them with: its alias, or the table's own name. Two names
      # for one table, as in a self-join, give the same relation, so their
      # columns count as the same. A subquery or function in the list is its
      # own relation, by its alias. A table counts by its name alone, so
      # public.t and t count as one.
      module Relations
        module_function

        def of(from_clause) = {}.tap { |map| from_clause.each { add(map, it) } }

        def add(map, node)
          case node.node
          when :range_var then table(map, node.range_var)
          when :join_expr then [node.join_expr.larg, node.join_expr.rarg].compact.each { add(map, it) }
          else name(node.inner)&.then { map[it] = [:alias, it] }
          end
        end

        def table(map, range) = map[name(range) || range.relname] = [:table, range.relname]

        def name(item) = item.respond_to?(:alias) ? item.alias&.aliasname : nil

        # The relation a qualified column reference names, or nil.
        def named(map, ref)
          fields = ref.fields
          map[fields[-2].string&.sval] if fields.size > 1
        end
      end

      private_constant :Sharing, :Keys, :Relations
    end
  end
end
