# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "index_candidate_error"
require_relative "boolean_fold"

module Quaack
  module Enclave
    # The SQL parsing behind IndexCandidate: its predicates and
    # IndexCandidate.from_ddl. It's private to the enclave namespace. Use
    # IndexCandidate instead.
    #
    # The SQL can hold real literals. So no error raised here includes the
    # SQL, or pg_query's own error, even as the cause, because pg_query's
    # message quotes the SQL.
    module IndexSql
      module_function

      # Parses a predicate as the WHERE clause of an otherwise empty SELECT,
      # and refuses it unless that SELECT has nothing but the WHERE clause.
      # That keeps a second statement, a UNION, or a stray ORDER BY out of
      # the DDL. Returns the parsed expression node. A key expression is
      # parsed the same way, and what names it in the errors.
      def parse_predicate(sql, what: "predicate")
        result = PgQuery.parse("SELECT WHERE #{sql}")
        stmts = result.tree.stmts
        select = stmts.first.stmt.select_stmt if stmts.size == 1
        where = select&.where_clause
        bare = PgQuery::SelectStmt.new(where_clause: where, limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        raise IndexCandidateError, "#{what} must be a single SQL expression" unless where && select == bare

        result.walk! { |node| check_predicate_node(node, what) }
        where
      rescue PgQuery::ParseError
        raise IndexCandidateError, "#{what} doesn't parse as SQL", cause: nil
      end

      # Every aggregate and window function in pg_catalog on Postgres 18. The
      # raw parse tree can't tell an aggregate call from any other call, so a
      # plain call like sum(b) is found by name. Any call with aggregate or
      # window syntax is caught whatever its name, and so are JSON_ARRAYAGG
      # and JSON_OBJECTAGG, which parse as their own nodes.
      AGGREGATE_AND_WINDOW_FUNCTIONS = %w[
        any_value array_agg avg bit_and bit_or bit_xor bool_and bool_or corr count covar_pop covar_samp cume_dist
        dense_rank every first_value json_agg json_agg_strict json_object_agg json_object_agg_strict
        json_object_agg_unique json_object_agg_unique_strict jsonb_agg jsonb_agg_strict jsonb_object_agg
        jsonb_object_agg_strict jsonb_object_agg_unique jsonb_object_agg_unique_strict lag last_value lead max min
        mode nth_value ntile percent_rank percentile_cont percentile_disc range_agg range_intersect_agg rank
        regr_avgx regr_avgy regr_count regr_intercept regr_r2 regr_slope regr_sxx regr_sxy regr_syy row_number
        stddev stddev_pop stddev_samp string_agg sum var_pop var_samp variance xmlagg
      ].to_set.freeze

      # Refuses what Postgres never allows in an index predicate and a parse
      # tree can show: parameters, subqueries, and aggregate, window, or
      # grouping calls. Function volatility needs the catalog, so it isn't
      # checked here (see DESIGN.md's volatility).
      def check_predicate_node(node, what = "predicate")
        problem = forbidden(node)
        raise IndexCandidateError, "#{what} can't use #{problem}" if problem
      end

      # What's wrong with node, as check_predicate_node describes it, or nil.
      # IndexDdlCheck uses it for index expressions too, where Postgres
      # refuses the same things.
      def forbidden(node)
        case node
        when PgQuery::ParamRef then "a parameter"
        when PgQuery::SubLink then "a subquery"
        when PgQuery::GroupingFunc, PgQuery::JsonArrayAgg, PgQuery::JsonObjectAgg
          "an aggregate, window, or grouping function"
        when PgQuery::FuncCall then "an aggregate, window, or grouping function" if aggregate?(node)
        end
      end

      def aggregate?(call) = aggregate_syntax?(call) || built_in_aggregate?(call)

      # WITHIN GROUP always fills agg_order, so it needs no check of its own.
      def aggregate_syntax?(call)
        [call.agg_star, call.agg_distinct, call.over, call.agg_filter].any? ||
          call.agg_order.any?
      end

      # This name check is a backstop, not a precise catalog lookup: an
      # unqualified call to a same-named user function is refused too (see
      # IndexCandidate's comment on the predicate), and it can't see
      # set-returning functions, DEFAULT, or merge_action(), which Postgres
      # also refuses here but a mechanical generator never emits. Nothing in
      # the supported SQL profile's WHERE clauses reaches those gaps, so it's
      # left as-is rather than extended to close them.
      def built_in_aggregate?(call)
        *schema, name = call.funcname.map { |n| n.string.sval }
        AGGREGATE_AND_WINDOW_FUNCTIONS.include?(name) && [[], ["pg_catalog"]].include?(schema)
      end

      # The predicate as pg_query deparses it, with each column compared
      # with true or false folded to the bare test (see BooleanFold), so
      # WHERE (deleted = true) and WHERE deleted make equal candidates.
      def normalize_predicate(sql) = deparse_predicate(BooleanFold.fold(parse_predicate(sql))).freeze

      # The predicate node as SQL. pg_query's deparser can write an
      # expression that means something else, such as (a = 1) IS NOT
      # DISTINCT FROM (b AND c) without its parentheses, so it must parse
      # back to the same node (see Deparse).
      def deparse_predicate(node, what: "predicate")
        Deparse.expression(node)
      rescue Deparse::Error
        raise IndexCandidateError, "#{what} changes meaning when pg_query deparses it", cause: nil
      end

      # See IndexCandidate.from_ddl and from_indexdef. With existing, WITH
      # storage parameters and NULLS NOT DISTINCT are dropped first.
      def read_index(sql, sources, existing: false)
        stmt = parse_index_stmt(sql)
        drop_existing_options(stmt) if existing
        candidate = candidate_from(stmt, sources)
        candidate if candidate&.to_ddl == PgQuery.deparse_stmt(comparable(stmt))
      end

      def parse_index_stmt(sql)
        stmts = PgQuery.parse(sql).tree.stmts
        return stmts.first.stmt.index_stmt if stmts.size == 1 && stmts.first.stmt.node == :index_stmt

        raise IndexCandidateError, "from_ddl takes exactly one CREATE INDEX statement"
      rescue PgQuery::ParseError
        raise IndexCandidateError, "from_ddl takes exactly one CREATE INDEX statement, and this doesn't parse",
              cause: nil
      end

      # Takes only the parts IndexCandidate holds. read_index then checks
      # that rendering them gives back the whole statement, so anything left
      # out here makes it return nil. So does anything the constructor refuses.
      def candidate_from(stmt, sources)
        where = stmt.where_clause
        IndexCandidate.new(
          table: table_name(stmt.relation),
          key: stmt.index_params.map { |n| IndexKeySql.key_column(n.index_elem) },
          include: stmt.index_including_params.map { |n| n.index_elem.name },
          access_method: stmt.access_method, predicate: where && deparse_predicate(where),
          unique: stmt.unique, sources:
        )
      rescue IndexCandidateError
        nil
      end

      # Storage parameters, such as fillfactor or deduplicate_items, change
      # how the index is stored, not what it can answer. A NULLS NOT
      # DISTINCT unique index is a btree on the same columns whose
      # uniqueness is stricter than plain UNIQUE, so reading it as plain
      # unique only understates it.
      def drop_existing_options(stmt)
        stmt.options.clear
        stmt.nulls_not_distinct = false
      end

      # nil for an unqualified table, which the constructor refuses.
      def table_name(range_var)
        TableName.new(schema: range_var.schemaname, name: range_var.relname) unless range_var.schemaname.empty?
      end

      # Changes the parsed statement in place to what to_ddl would render: no
      # name, each key column as IndexKeySql.comparable leaves it, and the
      # predicate's booleans folded, as the constructor stores them.
      # CONCURRENTLY and IF NOT EXISTS stay, so from_ddl returns nil for
      # them. pg_get_indexdef never prints either.
      def comparable(stmt)
        stmt.idxname = ""
        stmt.where_clause = BooleanFold.fold(stmt.where_clause) if stmt.where_clause
        stmt.index_params.each { |n| IndexKeySql.comparable(n.index_elem) }
        stmt
      end
    end

    private_constant :IndexSql
  end
end
