# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "node_rewrite"
require_relative "relation_qualifier"
require_relative "supported_sql"

module Quaack
  module Enclave
    # README step 3h: replace the functions that read the transaction's
    # clock with calls to quaack.clock_anchor(), so every run of the query
    # sees the time the production plan ran.
    #
    #   result = ClockAnchoring.anchor("SELECT ... WHERE created_at > CURRENT_DATE - 7", settings)
    #   result.sql           # => "SELECT ... WHERE created_at > quaack.clock_anchor()::pg_catalog.date - 7"
    #   result.replacements  # => [Replacement(original: "current_date",
    #                        #                 anchored: "quaack.clock_anchor()::pg_catalog.date")]
    #   ClockAnchoring.restore(result.sql, result.replacements)
    #   # => "SELECT ... WHERE created_at > current_date - 7"
    #
    # The inputs are the query, qualified by RelationQualifier, and the
    # Settings hash from the input plan's EXPLAIN (SETTINGS), or nil.
    #
    # Pipeline order: run 3d, VolatilityCheck, on the original query, then
    # anchor. quaack.clock_anchor() exists only on the run server (4a and
    # 4b), so 3d would find no such function in the production catalog.
    #
    # What's replaced, and with what. clock_anchor() returns timestamptz,
    # so each replacement casts it to the type and precision the original
    # had. Postgres computes CURRENT_DATE, LOCALTIMESTAMP, and LOCALTIME in
    # the session's TimeZone, and so does a cast from timestamptz:
    #
    #   now(), transaction_timestamp(), statement_timestamp(),
    #   CURRENT_TIMESTAMP     -> quaack.clock_anchor()
    #   CURRENT_TIMESTAMP(p)  -> quaack.clock_anchor()::pg_catalog.timestamptz(p)
    #   CURRENT_DATE          -> quaack.clock_anchor()::pg_catalog.date
    #   LOCALTIMESTAMP[(p)]   -> quaack.clock_anchor()::pg_catalog.timestamp[(p)]
    #   LOCALTIME[(p)]        -> quaack.clock_anchor()::pg_catalog.time[(p)]
    #
    # Nothing else changes: not CURRENT_TIME, not clock_timestamp() or
    # timeofday(), which 3d refuses as volatile, and no other function.
    #
    # Which now() is pg_catalog's. The SQL-value functions are keywords, so
    # they can't be anyone else's. A function call is replaced only when
    # it takes no arguments, has no FILTER, OVER, or the like, and is
    # either named pg_catalog.now (and so on) or has no schema at all. An
    # unqualified call resolves through the search path, and
    # RelationQualifier doesn't qualify function names. Postgres searches
    # pg_catalog first unless the path lists it somewhere else, and an
    # exact match in an earlier schema wins. So an unqualified call is
    # pg_catalog's when the plan's search_path doesn't list pg_catalog, or
    # lists it first. When the path puts any schema before pg_catalog, the
    # call might be someone else's function, so anchor raises Error (rule
    # clock_function_search_path) rather than guess. A function of that
    # name in any other schema, or with a database name in front, is left
    # alone.
    #
    # Restoring. Each Replacement holds the original expression and the
    # one that replaced it, both as SQL the deparser wrote. They're shape:
    # function names and a precision, never a literal. The list is in the
    # order a walk of the tree meets them. restore walks the SQL it's
    # given the same way and puts each original back where its anchored
    # expression is, so the SQL may have changed elsewhere since, such as
    # literals turned into placeholders by 3g. A query that already calls
    # quaack.clock_anchor() is refused (rule clock_anchor_in_query), since
    # restore couldn't tell that call from one anchor made. If the anchors
    # in the SQL don't match the list one for one, restore raises Error
    # (rule restore_mismatch).
    #
    # SQL comes out of Deparse.faithfully, so a deparse that changes the
    # query raises Deparse::Error. The query must use only what
    # SupportedSql lists, or SupportedSql::Error is raised. Error messages
    # never quote the query. A parse error is replaced rather than
    # wrapped, since pg_query's quote the text near the error, which can
    # be a literal.
    module ClockAnchoring
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      Result = Data.define(:sql, :parse, :replacements)
      Replacement = Data.define(:original, :anchored)

      ANCHOR = "quaack.clock_anchor()"
      ANCHOR_NAME = %w[quaack clock_anchor].freeze
      FUNCTIONS = %w[now transaction_timestamp statement_timestamp].freeze

      # Each SQL-value function replaced, and the cast that keeps its type,
      # if it needs one.
      SQL_VALUE_CASTS = {
        SVFOP_CURRENT_TIMESTAMP: nil, SVFOP_CURRENT_TIMESTAMP_N: "pg_catalog.timestamptz",
        SVFOP_CURRENT_DATE: "pg_catalog.date",
        SVFOP_LOCALTIMESTAMP: "pg_catalog.timestamp", SVFOP_LOCALTIMESTAMP_N: "pg_catalog.timestamp",
        SVFOP_LOCALTIME: "pg_catalog.time", SVFOP_LOCALTIME_N: "pg_catalog.time"
      }.freeze

      PRECISION_OPS = %i[SVFOP_CURRENT_TIMESTAMP_N SVFOP_LOCALTIMESTAMP_N SVFOP_LOCALTIME_N].freeze

      module_function

      def anchor(sql, settings)
        tree = parse(sql).tap { |result| SupportedSql.check!(result) }.tree
        originals = anchor_tree(tree)
        check_search_path!(settings) if originals.any? { |node| unqualified_call?(node) }
        anchored = Deparse.faithful_parse(tree)
        Result.new(sql: anchored.query, parse: anchored, replacements: originals.map { |node| record(node) })
      end

      def restore(sql, replacements)
        tree = parse(sql).tree
        pending = replacements.map { |r| [comparable(expression(r.anchored)), r.original] }
        NodeRewrite.each(tree) { |node| restored_node(node, pending) }
        mismatch!("the SQL has fewer clock anchors than the replacements") if pending.any?

        Deparse.faithfully(tree)
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("parse_error", "the query doesn't parse"), cause: nil
      end

      # Anchors the tree in place, and returns the nodes it replaced.
      def anchor_tree(tree)
        originals = []
        NodeRewrite.each(tree) { |node| anchored_node(node)&.tap { originals << node } }
        originals
      end

      # The node that replaces node, or nil when it isn't replaced.
      def anchored_node(node)
        raise Error.new("clock_anchor_in_query", "the query already calls #{ANCHOR}") if anchor_call?(node)

        sql = anchored_sql(node)
        sql && expression(sql)
      end

      def record(node)
        Replacement.new(original: Deparse.expression(node),
                        anchored: Deparse.expression(anchored_node(node)))
      end

      # The original that goes back in node's place, or nil when node
      # isn't one anchor made. Only an anchor call, or a cast of one, can be.
      def restored_node(node, pending)
        return unless anchor_call?(node) || (node.type_cast && anchor_call?(node.type_cast.arg))
        return expression(pending.shift.last) if pending.any? && comparable(node) == pending.first.first

        mismatch!("the SQL's clock anchors don't match the replacements") if anchor_call?(node)
      end

      def mismatch!(detail) = raise(Error.new("restore_mismatch", detail))

      # The anchored expression's SQL for a node anchor replaces, or nil.
      def anchored_sql(node)
        case node.node
        when :func_call then ANCHOR if clock_function?(node.func_call)
        when :sqlvalue_function then sql_value_anchor(node.sqlvalue_function)
        end
      end

      def sql_value_anchor(svf)
        return unless SQL_VALUE_CASTS.key?(svf.op)

        cast = SQL_VALUE_CASTS[svf.op]
        return ANCHOR unless cast

        precision = PRECISION_OPS.include?(svf.op) ? "(#{Integer(svf.typmod)})" : ""
        "#{ANCHOR}::#{cast}#{precision}"
      end

      def clock_function?(func)
        names = name_parts(func)
        plain_call?(func) && FUNCTIONS.include?(names.last) && [1, 2].include?(names.length) &&
          (names.length == 1 || names.first == "pg_catalog")
      end

      # No arguments, so no DISTINCT or VARIADIC either, which need one. A
      # call with no arguments has an ORDER BY only from WITHIN GROUP.
      def plain_call?(func)
        func.args.empty? && func.agg_order.empty? && func.agg_filter.nil? && func.over.nil? && !func.agg_star
      end

      def unqualified_call?(node) = node.func_call&.funcname&.length == 1

      def anchor_call?(node) = node.func_call && name_parts(node.func_call) == ANCHOR_NAME

      def name_parts(func) = func.funcname.map { |part| part.string.sval }

      def check_search_path!(settings)
        raw = settings&.fetch("search_path", nil) || RelationQualifier::DEFAULT_SEARCH_PATH
        schemas = split_path(raw)
        return if !schemas.include?("pg_catalog") || schemas.first == "pg_catalog"

        raise Error.new("clock_function_search_path",
                        "search_path #{raw} puts #{schemas.first} before pg_catalog, so an unqualified " \
                        "clock function may not be pg_catalog's")
      end

      def split_path(raw)
        RelationQualifier.split_identifiers(raw)
      rescue RelationQualifier::Error => e
        raise Error.new("bad_search_path", e.message), cause: nil
      end

      # The node for one expression's SQL.
      def expression(sql)
        PgQuery.parse("SELECT #{sql}").tree.stmts.first.stmt.select_stmt.target_list.first.res_target.val
      end

      # A copy of node with every location cleared, for comparing.
      def comparable(node)
        copy = node.class.decode(node.class.encode(node))
        Deparse.clear_locations(copy)
        copy
      end
    end
  end
end
