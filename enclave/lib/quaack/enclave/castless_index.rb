# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "index_candidate"
require_relative "index_sql"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # An index candidate as the report tells two apart (DESIGN.md 15a): the
    # same candidate, with every cast on a constant or on a bare column
    # taken out of its predicate.
    #
    #   CastlessIndex.key(a) == CastlessIndex.key(b)
    #
    # IndexCandidate keeps casts, since only the catalog can say what one
    # changes. So a partial index read from a plan, which prints
    # (status)::text = 'deleted'::text, and the same index from the query's
    # own text, status = 'deleted', are two candidates, and 5a tests both.
    # A reader of the report sees one index, so its lists send it once.
    # Sources don't count, as in IndexCandidate#==.
    #
    # This only groups lines of the report. Nothing is tested, built, or
    # dropped by it. A predicate the deparser can't write back faithfully
    # keeps its casts.
    #
    # Trust boundary. The key holds the predicate, so it's value-class
    # data, like the candidate. It's for comparing, never for sending.
    module CastlessIndex
      CASTLESS = %i[a_const column_ref].freeze

      module_function

      def key(candidate) = IndexCandidate.new(**candidate.to_h, predicate: predicate(candidate.predicate))

      def predicate(sql)
        return if sql.nil?

        holder = PgQuery::SelectStmt.new(where_clause: IndexSql.parse_predicate(sql))
        NodeRewrite.each(holder) { uncast(it) }
        Deparse.expression(holder.where_clause)
      rescue Deparse::Error, ArgumentError
        sql
      end

      # The constant or column under node's casts, or nil if node isn't a
      # cast of one.
      def uncast(node)
        inner = node
        inner = inner.type_cast.arg while inner.node == :type_cast
        inner if !inner.equal?(node) && CASTLESS.include?(inner.node)
      end
    end
  end
end
