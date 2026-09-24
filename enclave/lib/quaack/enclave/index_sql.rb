# frozen_string_literal: true

require "pg_query"

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
      # the DDL. Returns the parsed expression node.
      def parse_predicate(sql)
        result = PgQuery.parse("SELECT WHERE #{sql}")
        stmts = result.tree.stmts
        select = stmts.first.stmt.select_stmt if stmts.size == 1
        where = select&.where_clause
        bare = PgQuery::SelectStmt.new(where_clause: where, limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        raise ArgumentError, "predicate must be a single SQL expression" unless where && select == bare

        result.walk! { |node| check_predicate_node(node) }
        where
      rescue PgQuery::ParseError
        raise ArgumentError, "predicate doesn't parse as SQL", cause: nil
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
      # checked here (see README 3d).
      def check_predicate_node(node)
        problem = case node
                  when PgQuery::ParamRef then "a parameter"
                  when PgQuery::SubLink then "a subquery"
                  when PgQuery::GroupingFunc, PgQuery::JsonArrayAgg, PgQuery::JsonObjectAgg
                    "an aggregate, window, or grouping function"
                  when PgQuery::FuncCall then "an aggregate, window, or grouping function" if aggregate?(node)
                  end
        raise ArgumentError, "predicate can't use #{problem}" if problem
      end

      def aggregate?(call) = aggregate_syntax?(call) || built_in_aggregate?(call)

      # WITHIN GROUP always fills agg_order, so it needs no check of its own.
      def aggregate_syntax?(call)
        [call.agg_star, call.agg_distinct, call.over, call.agg_filter].any? ||
          call.agg_order.any?
      end

      def built_in_aggregate?(call)
        *schema, name = call.funcname.map { |n| n.string.sval }
        AGGREGATE_AND_WINDOW_FUNCTIONS.include?(name) && [[], ["pg_catalog"]].include?(schema)
      end

      # The predicate as pg_query deparses it.
      def normalize_predicate(sql) = PgQuery.deparse_expr(parse_predicate(sql)).freeze

      # The names of the columns a predicate uses, without repeats. A column
      # reference that isn't a bare name, such as t.a or t.*, comes back as
      # nil, since which column it means isn't certain. It raises what
      # parse_predicate raises.
      def predicate_columns(sql)
        parse_predicate(sql)
        names = []
        PgQuery.parse("SELECT WHERE #{sql}").walk! do |node|
          names << (node.fields.first.string&.sval if node.fields.size == 1) if node.is_a?(PgQuery::ColumnRef)
        end
        names.uniq
      end

      # See IndexCandidate.from_ddl.
      def read_index(sql, sources)
        stmt = parse_index_stmt(sql)
        candidate = candidate_from(stmt, sources)
        candidate if candidate&.to_ddl == PgQuery.deparse_stmt(comparable(stmt))
      end

      def parse_index_stmt(sql)
        stmts = PgQuery.parse(sql).tree.stmts
        return stmts.first.stmt.index_stmt if stmts.size == 1 && stmts.first.stmt.node == :index_stmt

        raise ArgumentError, "from_ddl takes exactly one CREATE INDEX statement"
      rescue PgQuery::ParseError
        raise ArgumentError, "from_ddl takes exactly one CREATE INDEX statement, and this doesn't parse", cause: nil
      end

      # Takes only the parts IndexCandidate holds. read_index then checks
      # that rendering them gives back the whole statement, so anything left
      # out here makes it return nil. So does anything the constructor refuses.
      def candidate_from(stmt, sources)
        where = stmt.where_clause
        IndexCandidate.new(
          table: table_name(stmt.relation),
          key: stmt.index_params.map { |n| key_column(n.index_elem) },
          include: stmt.index_including_params.map { |n| n.index_elem.name },
          access_method: stmt.access_method, predicate: where && PgQuery.deparse_expr(where),
          unique: stmt.unique, sources:
        )
      rescue ArgumentError
        nil
      end

      def table_name(range_var) = TableName.new(schema: range_var.schemaname, name: range_var.relname)

      def key_column(elem)
        IndexCandidate::KeyColumn.new(
          name: elem.name, direction: elem.ordering == :SORTBY_DESC ? :desc : :asc,
          nulls: { SORTBY_NULLS_FIRST: :first, SORTBY_NULLS_LAST: :last }[elem.nulls_ordering]
        )
      end

      # Changes the parsed statement in place to what to_ddl would render: no
      # name, and ASC or default nulls orderings left implicit. CONCURRENTLY
      # and IF NOT EXISTS stay, so from_ddl returns nil for them.
      # pg_get_indexdef never prints either.
      def comparable(stmt)
        stmt.idxname = ""
        stmt.index_params.each do |n|
          e = n.index_elem
          e.ordering = :SORTBY_DEFAULT if e.ordering == :SORTBY_ASC
          default_nulls = e.ordering == :SORTBY_DESC ? :SORTBY_NULLS_FIRST : :SORTBY_NULLS_LAST
          e.nulls_ordering = :SORTBY_NULLS_DEFAULT if e.nulls_ordering == default_nulls
        end
        stmt
      end
    end

    private_constant :IndexSql
  end
end
