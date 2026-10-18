# frozen_string_literal: true

require "pg_query"
require_relative "../../deparse"
require_relative "../tree"
require_relative "../or_to_union/arms"
require_relative "../distinct_key_removal/keys"

module Quaack
  module Enclave
    module RewriteRules
      class AggregateBeforeJoin
        # The parts of a SELECT the rule can take, or nil (see Shape.read).
        # keyed and other are the RangeVars of the key's table and of the
        # table it aggregates. pairs are the join's equalities, each
        # [condition, other's column]. outer and inner are the other
        # conditions, which read only keyed and only other. assumptions
        # state keyed's key.
        Shape = Data.define(:select, :keyed, :other, :pairs, :outer, :inner, :assumptions)

        # Reads a SELECT the rule can take.
        class Shape
          Keys = DistinctKeyRemoval::Keys
          Arms = OrToUnion::Arms

          # A Shape of select, or nil unless it fits (see the rule's own
          # comment).
          def self.read(select, catalog)
            items = Tree.from_items(select.from_clause) if plain?(select)
            conditions = Tree.inner_conditions(select.from_clause) if items && two_tables?(items)
            return unless conditions

            Reader.new(select, items.map(&:table), conditions + Tree.conjuncts(select.where_clause), catalog).shape
          end

          # Whether items are two plain tables under names of their own.
          # Tree.inner_conditions then refuses an outer join.
          def self.two_tables?(items) = items.size == 2 && Tree.tables?(items)

          # Whether select is one SELECT with a GROUP BY, no subquery
          # expression, and nothing bare? refuses.
          def self.plain?(select)
            select.op == :SETOP_NONE && select.group_clause.any? && Tree.find(select, PgQuery::SubLink).empty? &&
              bare?(select)
          end

          # Whether select has no DISTINCT, WINDOW, locking clause, WITH,
          # GROUP BY DISTINCT, or FETCH WITH TIES.
          def self.bare?(select)
            [select.distinct_clause, select.window_clause, select.locking_clause].all?(&:empty?) &&
              select.with_clause.nil? && !select.group_distinct && select.limit_option != :LIMIT_OPTION_WITH_TIES
          end

          # The name a select list item gives its column: its alias, its
          # column's name, or its function's name.
          def self.output_name(target)
            return target.name unless target.name.empty?

            val = target.val
            val.node == :column_ref ? val.column_ref.fields.last.string.sval : val.func_call.funcname.last.string.sval
          end

          # Every Node in node, each before those inside it.
          def self.nodes(node, found = [])
            case node
            when Google::Protobuf::RepeatedField then node.each { nodes(it, found) }
            when PgQuery::Node
              found << node
              nodes(node.inner, found)
            when Google::Protobuf::MessageExts then node.class.descriptor.each { nodes(it.get(node), found) }
            end
            found
          end

          # Reads one SELECT's parts, given its two tables and every
          # condition its FROM and WHERE AND.
          class Reader
            def initialize(select, tables, conditions, catalog)
              @select = select
              @tables = tables
              @conditions = conditions
              @catalog = catalog
            end

            def shape
              keyed = grouped_table
              return unless keyed

              @keyed = keyed
              @other = (@tables - [keyed]).first
              parts = split
              assumptions = key if parts && targets? && having? && sorts?
              Shape.new(select: @select, keyed:, other: @other, **parts, assumptions:) if assumptions
            end

            private

            # The table every GROUP BY item is a column of, or nil.
            def grouped_table
              names = @select.group_clause.map { column(it)&.first }.uniq
              @tables.find { Tree.refname(it) == names.first } if names.one?
            end

            # pairs, outer, and inner, or nil unless every condition is one
            # of them, the join has a pair, and no inner one can raise.
            def split
              parts = { pairs: [], outer: [], inner: [] }
              placed = @conditions.all? { place(it, parts) }
              parts if placed && parts[:pairs].any? && parts[:inner].none? { raises?(it) }
            end

            # Puts condition in its part, or gives nil if it has none.
            def place(condition, parts)
              pair = pair(condition)
              return parts[:pairs] << pair if pair

              tables = reads(condition)
              (tables.include?(name(@other)) ? parts[:inner] : parts[:outer]) << condition if tables
            end

            # [condition, other's column] for a plain = of a column of each
            # table, of one type, whose = is the type's default btree
            # family's, each with a deterministic collation or none.
            def pair(condition)
              own, theirs = Keys.sides(condition, name(@other))
              return unless own && theirs.first == name(@keyed)

              [condition, own.last] if Keys.comparable?(@catalog, [*pair_of(@other), own.last],
                                                        [*pair_of(@keyed), theirs.last])
            end

            # The names of the tables node reads, which must be one at most,
            # or nil if it reads a column not written name.column of one.
            def reads(node)
              names = Tree.find(node, PgQuery::ColumnRef).map { Tree.qualified(it)&.first }.uniq
              known = @tables.map { Tree.refname(it) }
              names if (names - known).empty? && names.size < 2
            end

            # Whether every select list item is a column of keyed, written
            # name.column, or an aggregate over other.
            def targets?
              @select.target_list.all? do |target|
                val = target.res_target.val
                column(val)&.first == name(@keyed) || aggregate?(val)
              end
            end

            # Whether node is a plain call of an aggregate that reads only
            # other, and can't raise on its rows.
            def aggregate?(node)
              call = node.func_call if node.node == :func_call
              return false unless call && plain_call?(call)

              parts = [call.args, call.agg_order, call.agg_filter].compact
              parts.all? { reads(it)&.all? { |table| table == name(@other) } } && parts.none? { raises?(it) }
            end

            # Whether call is an aggregate's, with no OVER, WITHIN GROUP, or
            # VARIADIC.
            def plain_call?(call)
              call.over.nil? && !call.agg_within_group && !call.func_variadic && call_aggregate?(call)
            end

            def raises?(node) = Arms.raises?(node, @catalog)

            def call_aggregate?(call)
              names = call.funcname.map { it.string.sval }
              names.size.between?(1, 2) && @catalog.only_aggregates?(*(names.size == 2 ? names : [nil, *names]))
            end

            # Whether the HAVING, if any, reads other only in aggregates over
            # it, and can't raise outside them.
            def having?
              having = @select.having_clause
              return true unless having

              having = Deparse.copy(having)
              calls = Shape.nodes(having).select { it.node == :func_call && aggregate?(it) }
              calls.each { it.a_const = PgQuery::A_Const.new(isnull: true) }
              Tree.find(having, PgQuery::ColumnRef).empty? && !raises?(having)
            end

            # Whether every ORDER BY item is an ordinal, an output's name,
            # or reads only keyed's columns, written name.column, and calls
            # no aggregate.
            def sorts? = @select.sort_clause.all? { sorted?(it.sort_by.node) }

            def sorted?(node)
              return true if node.node == :a_const && node.a_const.val == :ival

              bare = Tree.bare_name(node.column_ref) if node.node == :column_ref
              return output_names.include?(bare) if bare

              reads(node) == [name(@keyed)] && Tree.find_all(node, PgQuery::FuncCall).none? { call_aggregate?(it) }
            end

            def output_names = @select.target_list.map { Shape.output_name(it.res_target) }

            # unique and not_null for a key of keyed among the GROUP BY's
            # columns, each with a deterministic collation or none, or nil.
            def key
              columns = @select.group_clause.map { column(it).last }
              key = Keys.candidates(@catalog, @keyed, columns).find do |candidate|
                Keys.unique_not_null(@keyed, candidate).all? { @catalog.met?(it) } &&
                  candidate.all? { @catalog.column_info(*pair_of(@keyed), it).deterministic }
              end
              Keys.unique_not_null(@keyed, key) if key
            end

            def column(node) = (Tree.qualified(node.column_ref) if node.node == :column_ref)

            def name(table) = Tree.refname(table)

            def pair_of(table) = [table.schemaname, table.relname]
          end
        end
      end
    end
  end
end
