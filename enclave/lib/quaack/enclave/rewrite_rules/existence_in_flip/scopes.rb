# frozen_string_literal: true

require "pg_query"
require_relative "../tree"

module Quaack
  module Enclave
    module RewriteRules
      class ExistenceInFlip
        # The flip puts each side of an IN in the other's scope: the
        # original's FROM, its other conditions, and x go inside an EXISTS
        # under the subquery's FROM, and the subquery's FROM and WHERE go
        # to the top, where the original's FROM no longer is. Postgres
        # reads a bare name as a column of any query in scope before it
        # reads it as a FROM item's whole row, so a bare name that names a
        # FROM item on its own side, such as posts in posts IS NULL, could
        # read the other side's column of that name after the flip, or had
        # read it before.
        module Scopes
          module_function

          # Whether a bare name in the IN's two sides could change what it
          # reads. others are the original's conditions other than the IN.
          def captured?(from, others, link)
            sub = link.subselect.select_stmt
            [from.to_a + others + [link.testexpr], sub.from_clause.to_a + [sub.where_clause].compact]
              .any? { names_a_from_item?(it) }
          end

          def names_a_from_item?(nodes)
            names = Tree.find(nodes, PgQuery::RangeVar).map(&:relname) +
                    Tree.find(nodes, PgQuery::Alias).map(&:aliasname)
            Tree.find(nodes, PgQuery::ColumnRef).any? { |ref| names.include?(bare(ref)) }
          end

          def bare(ref) = (ref.fields.first.string.sval if ref.fields.size == 1 && ref.fields.first.node == :string)
        end
      end
    end
  end
end
