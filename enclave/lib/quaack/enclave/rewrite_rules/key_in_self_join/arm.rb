# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class KeyInSelfJoin
        # One SELECT of the IN's subquery: the whole subquery, or one arm of
        # its UNION or UNION ALL (IN gives the same for both, since it
        # doesn't count rows). inner is the name the arm reads the outer
        # table by, others the Tree::Items of its other tables, and
        # predicates every condition of its WHERE and its joins' ONs.
        #
        # Arm.all gives the arms, or nil unless every arm is one the rule
        # can rewrite:
        #
        # - It's a plain SELECT, with no GROUP BY, HAVING, WINDOW, ORDER
        #   BY, LIMIT, OFFSET, locking clause, WITH, or DISTINCT ON. A
        #   plain DISTINCT is fine, since IN doesn't count rows. A UNION has
        #   no ORDER BY, LIMIT, OFFSET, or WITH of its own.
        # - Its select list is only name2.k, where name2 is a FROM item
        #   that reads the outer table. That rules out aggregates and
        #   window functions.
        # - Its FROM holds only tables, each schema-qualified (so not a
        #   CTE), read without ONLY and without column aliases, joined only
        #   by plain inner or cross joins: no outer join, NATURAL, USING, or
        #   join alias. So the FROM is the list of its tables, and the ONs
        #   are more WHERE conditions.
        # - Every column in its conditions is written name.column, where
        #   name is one of the arm's own tables, and no condition has a
        #   subquery. So each condition can be moved by renaming, and none
        #   reads the outer query.
        Arm = Data.define(:inner, :others, :predicates) do
          def self.all(select, table, key)
            arms = selects(select)&.map { read(it, table, key) }
            arms if arms&.all?
          end

          # The SELECTs a UNION tree joins, or nil for another set
          # operation or a UNION with clauses of its own.
          def self.selects(select)
            return [select] if select.op == :SETOP_NONE
            return unless select.op == :SETOP_UNION && Tree.unlimited?(select) && select.with_clause.nil?

            left = selects(select.larg)
            right = selects(select.rarg)
            left + right if left && right
          end

          def self.read(select, table, key)
            items = Tree.from_items(select.from_clause)
            conditions = Tree.inner_conditions(select.from_clause)
            return unless Tree.plain_select?(select) && conditions && tables?(items)

            arm = new(inner: key_table(select, key), others: items, predicates: Tree.conjuncts(select.where_clause) +
                                                                                conditions)
            arm.without_inner(table)
          end

          # Whether every FROM item is a plain table under a name of its own.
          def self.tables?(items)
            items.all? { it.table && Tree.plain_table?(it.table) } && items.map(&:name).uniq.size == items.size
          end

          # The qualifier of the select list's one column, if that's key.
          def self.key_table(select, key)
            target = select.target_list.first.res_target if select.target_list.size == 1
            return unless target&.val&.node == :column_ref

            name, column = Tree.qualified(target.val.column_ref)
            name if column == key
          end

          # The arm with the outer table taken out of others, or nil if
          # inner doesn't name that table or a condition can't be moved.
          def without_inner(table)
            item = others.find { it.name == inner }
            return unless item && Tree.same_table?(item.table, table) && movable?

            with(others: others - [item])
          end

          # The conditions that stand for this arm in the outer query,
          # which reads the table as outer: the ones on the table alone,
          # moved to it, then an EXISTS on the other tables with the rest.
          def conditions(outer, names)
            moved, kept = predicates.partition { (qualifiers(it) - [inner]).empty? }
            renames = rename!(outer, names)
            moved += [exists(kept, renames)] unless others.empty?
            moved.empty? ? [Tree.true_const] : moved
          end

          private

          # Renames the table of every column in the conditions: inner to
          # outer, and each other table to a fresh alias. It returns the
          # new name for each old one.
          def rename!(outer, names)
            renames = { inner => outer, **others.to_h { [it.name, names.fresh(it.name)] } }
            columns(predicates).each { Tree.qualify!(it, renames.fetch(Tree.qualified(it).first)) }
            renames
          end

          def movable?
            names = others.map(&:name)
            Tree.find(predicates, PgQuery::SubLink).empty? && (qualifiers(predicates) - names).empty?
          end

          def columns(nodes) = Tree.find(nodes, PgQuery::ColumnRef)

          # The name each column in nodes is qualified by, nil for a column
          # that isn't written name.column.
          def qualifiers(nodes) = columns(nodes).map { Tree.qualified(it)&.first }.uniq

          def exists(kept, renames)
            link = Tree.exists
            select = link.sub_link.subselect.select_stmt
            others.each { select.from_clause << aliased(it.table, renames.fetch(it.name)) }
            where = Tree.all_of(kept)
            select.where_clause = where if where
            link
          end

          def aliased(range, name)
            range.alias = PgQuery::Alias.new(aliasname: name)
            PgQuery::Node.new(range_var: range)
          end
        end
      end
    end
  end
end
