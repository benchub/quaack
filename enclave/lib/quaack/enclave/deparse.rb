# frozen_string_literal: true

require "pg_query"
require_relative "deparse/parentheses"

module Quaack
  module Enclave
    # pg_query's deparser, with a round-trip guard (20260923-55).
    #
    #   Deparse.faithfully(parse.tree)   # => "SELECT ... FROM public.orders ..."
    #   Deparse.expression(where_node)   # => "status = 'open'"
    #   Deparse.statement(index_stmt)    # => "CREATE INDEX ON public.orders ..."
    #   # or raises Error "deparse_mismatch: ..."
    #
    # The deparser can write SQL that means something else. For example,
    # (status = $1) IS NOT DISTINCT FROM (true AND false) comes out as
    # status = $1 IS NOT DISTINCT FROM true AND false, and
    # (ARRAY(SELECT 1))[1] comes out as ARRAY(SELECT 1)[1], which doesn't
    # parse. So each method here deparses, parses the SQL again, and
    # compares the new tree with the one it deparsed. The SQL comes back
    # only when they match.
    #
    # The comparison is of the whole protobuf tree, constants included,
    # with only the int32 location fields cleared, since spacing and spelling
    # move every location. A fingerprint wouldn't do: it ignores constants.
    # What the deparser spells differently but parses to the same tree,
    # such as != for <>, CAST(x AS t) for x::t, or extra parentheses,
    # passes. The parse result's version isn't compared, since a tree built
    # by hand may not set it.
    #
    # A mismatch, or SQL that doesn't parse, raises Error with rule
    # deparse_mismatch and one fixed message. It has no cause: pg_query's
    # parse errors quote the text near the error, which can be a literal.
    # The tree given is never changed.
    #
    # expression doesn't use PgQuery.deparse_expr, which removes every
    # "SELECT WHERE " it finds, even inside a subquery.
    module Deparse
      class Error < StandardError
        attr_reader :rule

        def initialize
          @rule = "deparse_mismatch"
          super("#{rule}: pg_query's deparser changed the query, so it's refused")
        end
      end

      # The fields that hold where in the text a node was. Nothing else
      # the parser sets depends on spacing.
      LOCATIONS = %w[location name_location stmt_location stmt_len].freeze

      # Deparse allows this depth, so a copy should too.
      DEPTH = 1_000

      EXPRESSION_PREFIX = "SELECT WHERE "

      module_function

      # The SQL for a PgQuery::ParseResult.
      def faithfully(tree)
        faithful_parse(tree).query
      end

      # The deparsed SQL's own PgQuery.parse result, whose query is the SQL
      # and whose tree matches the one given.
      def faithful_parse(tree)
        sql = PgQuery.deparse(Parentheses.add!(copy(tree)))
        parse = reparse(sql)
        raise Error, cause: nil unless comparable(parse.tree) == comparable(tree)

        parse
      end

      # The SQL for one expression node, as a WHERE clause would hold it.
      def expression(node)
        select = PgQuery::SelectStmt.new(where_clause: node, limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        statement(select).delete_prefix(EXPRESSION_PREFIX)
      end

      # The SQL for one statement, such as a PgQuery::IndexStmt.
      def statement(stmt)
        faithfully(PgQuery::ParseResult.new(stmts: [PgQuery::RawStmt.new(stmt: PgQuery::Node.from(stmt))]))
      end

      def reparse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error, cause: nil
      end

      # A copy of the tree with its version and every location cleared.
      def comparable(tree)
        cleared = copy(tree)
        cleared.version = 0
        clear_locations(cleared)
        cleared
      end

      def copy(tree) = tree.class.decode(tree.class.encode(tree, recursion_limit: DEPTH), recursion_limit: DEPTH)

      # A location is an int32. CreateTableSpaceStmt's location is a string,
      # its directory, so it's compared like any other field.
      def location?(field) = field.type == :int32 && LOCATIONS.include?(field.name)

      def clear_locations(node)
        case node
        when Google::Protobuf::RepeatedField then node.each { |child| clear_locations(child) }
        when Google::Protobuf::MessageExts
          node.class.descriptor.each do |field|
            if location?(field) then field.clear(node)
            else clear_locations(field.get(node))
            end
          end
        end
      end
    end
  end
end
