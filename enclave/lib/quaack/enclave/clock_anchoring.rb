# frozen_string_literal: true

require "pg_query"
require_relative "anchored_names"
require_relative "clock_functions"
require_relative "clock_literals"
require_relative "literal_set"
require_relative "deparse"
require_relative "node_rewrite"
require_relative "relation_qualifier"
require_relative "supported_sql"

module Quaack
  module Enclave
    # DESIGN.md step 3h: replace the functions that read the transaction's
    # clock with calls to quaack.clock_anchor(), so every run of the query
    # sees the time the production plan ran.
    #
    #   result = ClockAnchoring.anchor("SELECT ... WHERE created_at > CURRENT_DATE - 7", settings)
    #   result.sql           # => "SELECT ... WHERE created_at > quaack.clock_anchor()::pg_catalog.date - 7"
    #   result.replacements  # => [Replacement(original: "current_date",
    #                        #                 anchored: "quaack.clock_anchor()::pg_catalog.date")]
    #   result.added_names   # => [] here; see below
    #   ClockAnchoring.restore(result.sql, result.replacements, result.added_names)
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
    # Clock-reading literals ('now', 'today', 'yesterday', 'tomorrow') are
    # anchored too, when placeholder_map, 3g's map, holds them and they're
    # read as a date or timestamp; statistics, 3c's entry, gives the column
    # types for that. See ClockLiterals. Their replacements record the
    # placeholder, as $1 or $1::date, so they're shape as well.
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
    # Names. Postgres names an output column with no AS, and a FROM
    # function with no alias, after the function, so anchoring would
    # rename them: now() is "now", but quaack.clock_anchor() is
    # "clock_anchor". AnchoredNames writes the original name in wherever
    # it changed, and added_names records each one by its slot, so
    # restore takes them off again. It raises restore_mismatch when a
    # slot doesn't carry the name that was added there. The names are
    # function and keyword names, so they're shape too.
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

      Result = Data.define(:sql, :parse, :replacements, :added_names)
      AddedName = AnchoredNames::Added
      Replacement = Data.define(:original, :anchored)

      ANCHOR = ClockFunctions::ANCHOR
      ANCHOR_NAME = %w[quaack clock_anchor].freeze

      module_function

      def anchor(sql, settings, placeholder_map: {}, statistics: nil)
        tree = parse(sql).tap { |result| SupportedSql.check!(result) }.tree
        found = clock_literals(sql, placeholder_map, statistics)
        names = AnchoredNames.implicit_names(tree)
        originals = anchor_tree(tree, found)
        check_search_path!(settings) if originals.any? { |node| unqualified_call?(node) }
        result(tree, originals.map { |node| record(node, found) }, AnchoredNames.keep(tree, names))
      end

      def clock_literals(sql, placeholder_map, statistics)
        ClockLiterals.find(placeholder_map, statistics) { LiteralSet.feeds(parse(sql), it) }
      end

      def result(tree, replacements, added_names)
        anchored = Deparse.faithful_parse(tree)
        Result.new(sql: anchored.query, parse: anchored, replacements:,
                   added_names:)
      end

      def restore(sql, replacements, added_names)
        tree = parse(sql).tree
        pending = replacements.map { |r| [comparable(expression(r.anchored)), r.original] }
        NodeRewrite.each(tree) { |node| restored_node(node, pending) }
        mismatch!("the SQL has fewer clock anchors than the replacements") if pending.any?
        strip_names(tree, added_names)

        Deparse.faithfully(tree)
      end

      def strip_names(tree, added_names)
        AnchoredNames.strip(tree, added_names)
      rescue AnchoredNames::Mismatch
        mismatch!("the SQL's names don't match the ones anchor added")
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("parse_error", "the query doesn't parse"), cause: nil
      end

      # Anchors the tree in place, and returns the nodes it replaced.
      def anchor_tree(tree, found)
        originals = []
        NodeRewrite.each(tree) { |node| anchored_node(node, found)&.tap { originals << node } }
        originals
      end

      # The node that replaces node, or nil when it isn't replaced.
      def anchored_node(node, found)
        raise Error.new("clock_anchor_in_query", "the query already calls #{ANCHOR}") if anchor_call?(node)

        refuse_database_qualified!(node)

        sql = ClockFunctions.anchored_sql(node)
        sql ? expression(sql) : ClockLiterals.anchored_node(node, found)
      end

      # db.pg_catalog.now() reads the clock when db is the current database.
      def refuse_database_qualified!(node)
        return unless node.func_call&.funcname&.length == 3

        trimmed = PgQuery::Node.decode(PgQuery::Node.encode(node))
        trimmed.func_call.funcname.shift
        return unless ClockFunctions.anchored_sql(trimmed)

        raise Error.new("database_qualified_function", "a clock function named with its database isn't supported")
      end

      def record(node, found)
        Replacement.new(original: Deparse.expression(node),
                        anchored: Deparse.expression(anchored_node(node, found)))
      end

      # The original that goes back in node's place, or nil when node
      # isn't one anchor made. Only an anchor call, or a cast (of one, or
      # for a clock literal, of an expression over one), can be.
      def restored_node(node, pending)
        return unless anchor_call?(node) || node.type_cast
        return expression(pending.shift.last) if pending.any? && comparable(node) == pending.first.first

        mismatch!("the SQL's clock anchors don't match the replacements") if anchor_call?(node)
      end

      def mismatch!(detail) = raise(Error.new("restore_mismatch", detail))

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
