# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module RewriteRules
      class SubqueryDistinctRemoval
        # Finds the SELECTs whose reader ignores duplicates and order.
        #
        # Readers.in(tree) gives, in tree order, every SELECT, a set
        # operation included, that is either:
        #
        # - the subquery of an IN or = ANY, NOT IN included, or of a <> ALL.
        #   Each asks only whether some row, or no row, of the subquery
        #   equals the value it tests, so how many copies of a row there
        #   are, and in what order they come, can't change its answer. The
        #   = and <> may be written OPERATOR(pg_catalog.=) and the like.
        # - an arm of such a subquery's set operation, or an arm under a
        #   UNION, INTERSECT, or EXCEPT without ALL anywhere, which dedupes
        #   what its arms give.
        #
        # An arm takes its reader's blindness through a UNION ALL or an
        # INTERSECT ALL above it, since each gives the same set of rows for
        # any count of each row in its arms, unless it has a LIMIT or
        # OFFSET of its own, which picks rows by their count and order.
        # EXCEPT ALL subtracts counts, so it stops the walk: one more copy
        # of a row on either side can add the row or take it away.
        #
        # EXISTS isn't a reader here, since Postgres already drops these
        # clauses from an EXISTS subquery. A scalar subquery, ARRAY(...), a
        # derived table, a CTE, and the statement itself see every row.
        module Readers
          EQUALS = [[], ["="], %w[pg_catalog =]].freeze
          NOT_EQUALS = [["<>"], %w[pg_catalog <>]].freeze
          ARMS = %w[larg rarg].freeze
          BLIND_ALL = %i[SETOP_UNION SETOP_INTERSECT].freeze

          module_function

          def in(tree) = walk(tree, false, [])

          # Walks node, which is blind when its reader ignores duplicates
          # and order. Only a SubLink's SELECT and a set operation's arms
          # can be; everything inside a SELECT starts over.
          def walk(node, blind, found)
            case node
            when PgQuery::SubLink then sub_link(node, found)
            when PgQuery::SelectStmt then select(node, blind, found)
            when PgQuery::Node then walk(node.inner, blind, found)
            when Google::Protobuf::RepeatedField then node.each { walk(it, false, found) }
            when Google::Protobuf::MessageExts then node.class.descriptor.each { walk(it.get(node), false, found) }
            end
            found
          end

          def sub_link(link, found)
            walk(link.testexpr, false, found)
            walk(link.subselect, reader?(link), found)
          end

          def select(select, blind, found)
            found << select if blind
            arms = select.op != :SETOP_NONE && (!select.all || (blind && passes?(select)))
            select.class.descriptor.each { walk(it.get(select), arms && ARMS.include?(it.name), found) }
          end

          def reader?(link)
            names = link.oper_name.map { it.string.sval }
            case link.sub_link_type
            when :ANY_SUBLINK then EQUALS.include?(names)
            when :ALL_SUBLINK then NOT_EQUALS.include?(names)
            else false
            end
          end

          # Whether a set operation with ALL gives its arms its reader's
          # blindness.
          def passes?(select)
            BLIND_ALL.include?(select.op) && select.limit_count.nil? && select.limit_offset.nil?
          end
        end
      end
    end
  end
end
