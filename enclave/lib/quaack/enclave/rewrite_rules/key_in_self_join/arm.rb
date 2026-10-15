# frozen_string_literal: true

require "pg_query"
require_relative "../tree"
require_relative "columns"

module Quaack
  module Enclave
    module RewriteRules
      class KeyInSelfJoin
        # One SELECT of the IN's subquery: the whole subquery, or one arm of
        # its UNION or UNION ALL (IN gives the same for both, since it
        # doesn't count rows). inner is the name the arm reads the outer
        # table by, others the Tree::Items of its other tables, predicates
        # every condition of its WHERE and its joins' ONs, and columns the
        # Columns that reads its columns by its own tables.
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
        # - Every column in its conditions is one of the arm's own tables':
        #   written name.column, or bare and found in just one of its
        #   tables by the catalog (see Columns). No condition has a
        #   subquery. So each condition can be moved by qualifying and
        #   renaming, and none reads the outer query.
        Arm = Data.define(:inner, :others, :predicates, :columns) do
          def self.all(select, table, key, catalog)
            arms = selects(select)&.map { read(it, table, key, catalog) }
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

          def self.read(select, table, key, catalog)
            items = Tree.from_items(select.from_clause)
            conditions = Tree.inner_conditions(select.from_clause)
            return unless Tree.plain_select?(select) && conditions && Tree.tables?(items)

            columns = Columns.new(items:, catalog:)
            arm = new(inner: key_table(select, key, columns), others: items,
                      predicates: Tree.conjuncts(select.where_clause) + conditions, columns:)
            arm.without_inner(table)
          end

          # The table of the select list's one column, if that's key.
          def self.key_table(select, key, columns)
            target = select.target_list.first.res_target if select.target_list.size == 1
            return unless target&.val&.node == :column_ref

            name, column = columns.resolve(target.val.column_ref)
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

          # Writes every column in the conditions as name.column, with its
          # table renamed: inner to outer, and each other table to a fresh
          # alias. It returns the new name for each old one.
          def rename!(outer, names)
            renames = { inner => outer, **others.to_h { [it.name, names.fresh(it.name)] } }
            refs(predicates).each { requalify!(it, renames) }
            renames
          end

          # Writes ref as name.column, name the new name of its table.
          def requalify!(ref, renames)
            table, column = columns.resolve(ref)
            ref.fields.clear
            [renames.fetch(table), column].each { ref.fields << Tree.string(it) }
          end

          def movable?
            names = others.map(&:name)
            Tree.find(predicates, PgQuery::SubLink).empty? && (qualifiers(predicates) - names).empty?
          end

          def refs(nodes) = Tree.find(nodes, PgQuery::ColumnRef)

          # The table each column in nodes is of, nil for a column that
          # isn't one of the arm's tables' (see Columns).
          def qualifiers(nodes) = refs(nodes).map { columns.resolve(it)&.first }.uniq

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
