# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The SQL the enclave's walkers support. Anything else is refused.
    #
    #   SupportedSql.check!(PgQuery.parse(sql))
    #   # => nil, or raises Error "unsupported_construct: RangeTableSample"
    #
    # The walkers that read a query's parse (RelationQualifier,
    # VolatilityCheck, GeneratorOne, and PredicateAtoms) call it first, so
    # each only has to be right for what's listed here. Supporting more is its own task
    # after version 1. The inbound checks for rewrite candidates, and input
    # intake, call it too once they're built.
    #
    # The list is pg_query node types, plus what's allowed inside a few of
    # them. check! walks the whole parse and refuses the first node, in
    # tree order, that isn't on it.
    #
    # A query is exactly one SELECT, set operations (UNION, INTERSECT, and
    # EXCEPT) and VALUES included. It can have:
    # - FROM: tables (ONLY too), joins of every type with ON, USING, or
    #   NATURAL, subqueries (LATERAL too), and one plain function call,
    #   such as generate_series or unnest, WITH ORDINALITY or not.
    # - WITH: CTEs, RECURSIVE, MATERIALIZED, and NOT MATERIALIZED.
    # - Expressions: columns, constants, $n parameters, casts, function
    #   calls, aggregates (DISTINCT, ORDER BY, FILTER, and WITHIN GROUP),
    #   window functions (OVER, named windows, and frames), AND, OR, NOT,
    #   IS NULL, IS TRUE and its kin, CASE, subqueries (EXISTS, IN, ANY,
    #   ALL, scalar, and ARRAY), COALESCE, GREATEST, LEAST, NULLIF, ARRAY[],
    #   array subscripts and slices, COLLATE, the SQL-value functions
    #   (CURRENT_DATE and friends), and named or VARIADIC arguments.
    # - The operators in A_EXPR_KINDS, and the SQL-syntax functions in
    #   SQL_SYNTAX_FUNCTIONS.
    # - DISTINCT, DISTINCT ON, GROUP BY (DISTINCT too) with plain
    #   expressions, HAVING, WINDOW, ORDER BY (USING too), LIMIT, OFFSET,
    #   and FETCH FIRST (WITH TIES too). They're common and use no node
    #   that isn't listed for something else.
    # - Row comparisons for keyset pagination, (a, b) < ($1, $2), with the
    #   operators in ROW_COMPARE_OPERATORS.
    #
    # Refused, each a family that gets its own task after version 1:
    # - Any statement but SELECT, even inside a CTE: INSERT, UPDATE,
    #   DELETE, MERGE, EXPLAIN, and the rest. Also SELECT INTO, and locking
    #   clauses such as FOR UPDATE, which rewrite candidates can't have
    #   either.
    # - TABLESAMPLE, ROWS FROM over several functions, a column definition
    #   list, anything but a function call in a function's place in FROM,
    #   and table functions (JSON_TABLE and XMLTABLE).
    # - CTE CYCLE and SEARCH.
    # - ROW(...) outside a row comparison, and row comparisons other than
    #   those in ROW_COMPARE_OPERATORS, such as (a, b) IN (SELECT ...).
    # - GROUPING SETS, ROLLUP, CUBE, and GROUPING().
    # - The XML and the SQL/JSON functions and predicates.
    # - SIMILAR TO.
    # - Field selection written with parentheses, such as (t).x or
    #   (f(x)).*, which can call a function the volatility check doesn't
    #   see. The same call written as t.f parses as a plain column
    #   reference, so the list can't tell it from a column, and it isn't
    #   refused here (see 20260923-35).
    # - SQL-syntax functions not in the list, such as normalize, IS
    #   NORMALIZED, SYSTEM_USER, and COLLATION FOR.
    # - Everything else pg_query can parse, such as DEFAULT and
    #   merge_action().
    #
    # The message names the node type, and the operator kind, subquery
    # kind, or function where that's what was refused. That's shape: it
    # never quotes the query.
    module SupportedSql
      class Error < StandardError
        attr_reader :rule

        def initialize(detail)
          @rule = "unsupported_construct"
          super("#{rule}: #{detail}")
        end
      end

      # Each supported node type, and the method that checks what's inside
      # it, or nil when all of it is supported. A PgQuery::Node only wraps
      # one of these, so it's never checked itself.
      NODES = {
        # The statement.
        PgQuery::ParseResult => :one_statement, PgQuery::RawStmt => nil, PgQuery::SelectStmt => nil,
        # FROM.
        PgQuery::RangeVar => nil, PgQuery::Alias => nil, PgQuery::JoinExpr => nil,
        PgQuery::RangeSubselect => nil, PgQuery::RangeFunction => :range_function,
        # WITH.
        PgQuery::WithClause => nil, PgQuery::CommonTableExpr => nil,
        # Expressions.
        PgQuery::ResTarget => nil, PgQuery::ColumnRef => nil, PgQuery::A_Star => nil, PgQuery::A_Const => nil,
        PgQuery::ParamRef => nil, PgQuery::TypeCast => nil, PgQuery::TypeName => nil,
        PgQuery::FuncCall => :func_call, PgQuery::NamedArgExpr => nil, PgQuery::WindowDef => nil,
        PgQuery::SortBy => nil, PgQuery::A_Expr => :a_expr, PgQuery::BoolExpr => nil, PgQuery::NullTest => nil,
        PgQuery::BooleanTest => nil, PgQuery::CaseExpr => nil, PgQuery::CaseWhen => nil,
        PgQuery::SubLink => :sublink, PgQuery::CoalesceExpr => nil, PgQuery::MinMaxExpr => nil,
        PgQuery::A_ArrayExpr => nil, PgQuery::A_Indirection => :indirection, PgQuery::A_Indices => nil,
        PgQuery::CollateClause => nil, PgQuery::SQLValueFunction => nil,
        # Values.
        PgQuery::String => nil, PgQuery::Integer => nil, PgQuery::Float => nil, PgQuery::Boolean => nil,
        PgQuery::BitString => nil, PgQuery::List => nil
      }.freeze

      # The A_Expr kinds: operators, ANY and ALL, IS [NOT] DISTINCT FROM,
      # NULLIF, IN, LIKE, ILIKE, and BETWEEN in each form. Not SIMILAR TO.
      A_EXPR_KINDS = %i[
        AEXPR_OP AEXPR_OP_ANY AEXPR_OP_ALL AEXPR_DISTINCT AEXPR_NOT_DISTINCT AEXPR_NULLIF AEXPR_IN AEXPR_LIKE
        AEXPR_ILIKE AEXPR_BETWEEN AEXPR_NOT_BETWEEN AEXPR_BETWEEN_SYM AEXPR_NOT_BETWEEN_SYM
      ].freeze

      # EXISTS, x IN or op ANY (SELECT ...), op ALL (SELECT ...), a scalar
      # subquery, and ARRAY(SELECT ...).
      SUBLINK_TYPES = %i[EXISTS_SUBLINK ANY_SUBLINK ALL_SUBLINK EXPR_SUBLINK ARRAY_SUBLINK].freeze

      # The functions the parser writes as FuncCalls in SQL syntax rather
      # than as calls, that are supported: extract(field FROM x), overlay,
      # position, substring, the forms of trim, and AT TIME ZONE and AT
      # LOCAL. Each takes ordinary arguments, except extract's field, which
      # the parser stores as a string constant. PredicateAtoms keeps that
      # field when it's one Postgres documents, and redacts it otherwise.
      # Others, such as normalize(x, NFC), take keywords the walkers would
      # read as values.
      SQL_SYNTAX_FUNCTIONS = %w[
        pg_catalog.extract pg_catalog.overlay pg_catalog.position pg_catalog.substring
        pg_catalog.btrim pg_catalog.ltrim pg_catalog.rtrim pg_catalog.timezone
      ].freeze

      # The operators a row comparison can use, such as the keyset
      # pagination (created_at, id) < ($1, $2). Both sides are rows of the
      # same length, two or more, written (a, b) or ROW(a, b). A row
      # anywhere else, or nested in one, is refused as RowExpr.
      ROW_COMPARE_OPERATORS = %w[< <= > >= = <>].freeze

      module_function

      # Whether this A_Expr is a supported row comparison.
      def row_comparison?(expr)
        rows = [expr.lexpr&.row_expr, expr.rexpr&.row_expr]
        row_operator?(expr) && rows.all? && rows[0].args.size >= 2 && rows[0].args.size == rows[1].args.size
      end

      def row_operator?(expr)
        expr.kind == :AEXPR_OP && ROW_COMPARE_OPERATORS.include?(expr.name.first.string&.sval)
      end

      def check!(parse)
        walk(parse.tree)
        nil
      end

      def walk(node)
        case node
        when Google::Protobuf::RepeatedField then node.each { |child| walk(child) }
        when PgQuery::Node then walk(node.inner)
        when Google::Protobuf::MessageExts
          check_node(node)
          walk_fields(node)
        end
      end

      # A row comparison's rows aren't checked themselves, only what's in
      # them.
      def walk_fields(node)
        return walk_row_comparison(node) if node.is_a?(PgQuery::A_Expr) && row_comparison?(node)

        node.class.descriptor.each { |field| walk(field.get(node)) }
      end

      def walk_row_comparison(expr)
        walk(expr.name)
        walk(expr.lexpr.row_expr.args)
        walk(expr.rexpr.row_expr.args)
      end

      def check_node(node)
        type = node.class.name.split("::").last
        raise Error.new(type), cause: nil unless NODES.key?(node.class)

        checker = NODES[node.class]
        detail = checker && send(checker, node)
        raise Error.new("#{type} #{detail}"), cause: nil if detail
      end

      # Each checker returns what's wrong, or nil.

      def one_statement(result)
        count = result.stmts.size
        "with #{count} statements, not one" unless count == 1
      end

      def range_function(range)
        return "with ROWS FROM over several functions" if range.functions.size > 1

        function = range.functions.first.list.items.first
        "over #{function.inner.class.name.split("::").last}" unless function.func_call
      end

      def func_call(func)
        case func.funcformat
        when :COERCE_EXPLICIT_CALL then nil
        when :COERCE_SQL_SYNTAX
          name = func.funcname.map { |part| part.string.sval }.join(".")
          "#{name} written in SQL syntax" unless SQL_SYNTAX_FUNCTIONS.include?(name)
        else "written as #{func.funcformat}"
        end
      end

      def a_expr(expr) = (expr.kind.to_s unless A_EXPR_KINDS.include?(expr.kind))

      def sublink(link) = (link.sub_link_type.to_s unless SUBLINK_TYPES.include?(link.sub_link_type))

      # Array subscripts and slices only. Field selection, (t).x, can call
      # a function. t.f, a ColumnRef, isn't caught here.
      def indirection(indirection)
        "other than array subscripts" unless indirection.indirection.all?(&:a_indices)
      end
    end
  end
end
