# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class DistinctJoinToExists
        # What each column of a query reads, given the Tree::Items of its
        # FROM, all plain tables, and the Catalog that lists their columns.
        # Postgres finds a column the same way: name.column is that item's
        # column, and a bare column is the column of the one item that has
        # it. With none, or more than one, it's refused here.
        #
        # A subquery brings its own FROM's items into scope, ahead of the
        # query's, as Postgres does: name.column is the column of the
        # nearest item of that name, and a bare column is that of the
        # nearest items that have it. A column a subquery's own item gives
        # reads nothing of the query's, so it isn't listed. Only a subquery
        # whose FROM is plain tables and nothing else, under names of their
        # own, with no WITH or set operation, is read; any other makes the
        # whole read nil. A join there is refused too, since an ON sees
        # only its join's tables, not the rest of that FROM.
        Columns = Data.define(:items, :catalog) do
          # [name, column] for the column ref reads, [name, :star] for a
          # name.*, and nil for a ref this can't resolve: a bare *, three
          # parts or more, a name no item has, a column its item hasn't
          # (which may be a function call, f(t), written t.f), or a bare
          # column that no item has, or that more than one has.
          def resolve(ref)
            fields = fields(ref)
            case ref.fields.map(&:node)
            when %i[string string] then qualified(*fields)
            when %i[string a_star] then [fields.first, :star] if item(fields.first)
            when %i[string] then owner(fields.first)
            end
          end

          # What every column in nodes reads of the query's items, as
          # resolve gives it, or nil if one can't be resolved. Columns of a
          # subquery's own items are left out.
          def reads(nodes, scopes = [])
            refs, selects = Outside.new.walk(nodes)
            found = refs.map { scopes.empty? ? resolve(it) : inner(it, scopes) }
            return unless found.all?

            nested = selects.map { subquery(it, scopes) }
            found.reject { it == :inner } + nested.flatten(1) if nested.all?
          end

          private

          # What the subquery select reads of the query's items, or nil.
          def subquery(node, scopes)
            select = node.select_stmt if node.node == :select_stmt
            return unless select && select.op == :SETOP_NONE && select.with_clause.nil?
            return unless select.from_clause.all? { it.node == :range_var }

            own = Tree.from_items(select.from_clause)
            reads([select], [own, *scopes]) if Tree.tables?(own)
          end

          # What ref, inside subqueries whose items are scopes, innermost
          # first, reads: :inner for a column of one of their items, the
          # query's column as resolve gives it, or nil. Postgres takes
          # name.column and name.* from the nearest item of that name, so
          # one a subquery's item has a name for is that item's, even when
          # it hasn't the column: then it's a function of the item's row,
          # f(name), which reads nothing else. A bare column is the nearest
          # scope's whose items have it. A star of the query's items is
          # refused, and a bare one is the innermost subquery's own, since
          # Postgres refuses a bare * with no FROM.
          def inner(ref, scopes)
            fields = fields(ref)
            case ref.fields.map(&:node)
            when %i[string string] then inner_qualified(scopes, *fields)
            when %i[string a_star] then (:inner if inner?(scopes, fields.first))
            when %i[a_star] then :inner
            when %i[string] then inner_bare(scopes, fields.first)
            end
          end

          def fields(ref) = ref.fields.map { it.node == :string ? it.string.sval : it.node }

          def inner?(scopes, name) = scopes.any? { |items| items.any? { it.name == name } }

          def inner_qualified(scopes, name, column) = inner?(scopes, name) ? :inner : qualified(name, column)

          def inner_bare(scopes, column)
            owners = scopes.lazy.map { |items| items.select { own?(it, column) } }.find(&:any?)
            return owner(column) unless owners

            :inner if owners.size == 1
          end

          def item(name) = items.find { it.name == name }

          def qualified(name, column) = ([name, column] if own?(item(name), column))

          def own?(item, column)
            item && catalog.column_names(item.table.schemaname, item.table.relname).include?(column)
          end

          def owner(column)
            owners = items.select { own?(it, column) }
            [owners.first.name, column] if owners.size == 1
          end
        end

        # Finds the column refs in a tree outside every subquery, and the
        # subqueries themselves: a SubLink's test is outside it, and its
        # SELECT is the subquery.
        class Outside
          def walk(node, refs = [], selects = [])
            case node
            when PgQuery::ColumnRef then refs << node
            when PgQuery::SubLink then sub_link(node, refs, selects)
            when Array, Google::Protobuf::RepeatedField then node.each { walk(it, refs, selects) }
            when PgQuery::Node then walk(node.inner, refs, selects)
            when Google::Protobuf::MessageExts
              node.class.descriptor.each { |field| walk(field.get(node), refs, selects) }
            end
            [refs, selects]
          end

          private

          def sub_link(link, refs, selects)
            walk(link.testexpr, refs, selects) if link.testexpr
            selects << link.subselect
          end
        end
      end
    end
  end
end
