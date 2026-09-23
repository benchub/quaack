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
        stmts = PgQuery.parse("SELECT WHERE #{sql}").tree.stmts
        select = stmts.first.stmt.select_stmt if stmts.size == 1
        where = select&.where_clause
        bare = PgQuery::SelectStmt.new(where_clause: where, limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        return where if where && select == bare

        raise ArgumentError, "predicate must be a single SQL expression"
      rescue PgQuery::ParseError
        raise ArgumentError, "predicate doesn't parse as SQL", cause: nil
      end

      # The predicate as pg_query deparses it.
      def normalize_predicate(sql) = PgQuery.deparse_expr(parse_predicate(sql)).freeze

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
