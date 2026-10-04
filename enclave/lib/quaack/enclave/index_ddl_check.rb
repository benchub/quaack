# frozen_string_literal: true

require "pg_query"
require_relative "parser_version"
require_relative "deparse"
require_relative "index_sql"
require_relative "supported_sql"
require_relative "table_name"
require_relative "volatility_check"

module Quaack
  module Enclave
    # The inbound check for index DDL (DESIGN.md, "What goes into the
    # enclave"). The DDL comes from the LLM in llm-index-ideas and llm-index-refine, or from later
    # steps, so it's untrusted. This check runs on it before anything else
    # does.
    #
    #   IndexDdlCheck.check(sql, tables, settings, connection)
    #   # => Accepted(sql: "CREATE INDEX ON public.orders USING btree (status) WHERE ...",
    #   #             parse: PgQuery::ParseResult, table: TableName)
    #   # or raises Error "unknown_relation: sales.refunds isn't a table the query uses"
    #
    # The inputs:
    # - sql, the DDL's text.
    # - tables, the TableNames of the tables the query uses: the original's
    #   qualify Relations, or a rewrite candidate's own relations when the index
    #   is for that candidate. qualify already makes sure they're plain tables,
    #   so this check doesn't look them up.
    # - settings, the Settings hash from the input plan's EXPLAIN
    #   (SETTINGS), or nil, as RelationQualifier takes it. Its search_path
    #   is used only to look up unqualified function and operator names.
    # - connection, a PG connection to the production database. Only the
    #   catalog is read, with plain SELECTs.
    #
    # The checks run in this order, and the first one that fails wins:
    #
    # 1. unparsable: pg_query can't parse it. pg_query's own message quotes
    #    the text near the error, so it's replaced, not wrapped.
    # 2. not_create_index: it isn't exactly one statement, or that
    #    statement isn't a CREATE INDEX.
    # 3. concurrently, unique, nulls_not_distinct, tablespace, on_only, and
    #    storage_options, in that order: it uses CONCURRENTLY, UNIQUE, NULLS
    #    NOT DISTINCT, TABLESPACE, ON ONLY, or WITH (...) storage options.
    #    IndexCandidate can't hold storage options, so from_ddl would return
    #    nil and the candidate would be lost without a word; refusing says
    #    why. IF NOT EXISTS is allowed. Every index method is allowed, as are
    #    expression keys, operator classes with or without parameters,
    #    collations, directions, NULLS FIRST and LAST, and INCLUDE.
    # 4. unqualified_table: the table has no schema. It isn't resolved
    #    through the search path.
    # 5. unknown_relation: the table isn't one of tables, or is named with
    #    a database in front.
    # 6. forbidden_in_index: a key expression (INCLUDE's too) or the WHERE
    #    predicate uses what Postgres never allows in an index: a $n
    #    parameter, a subquery, or an aggregate, window, or grouping call.
    #    IndexSql.forbidden decides, as it does for IndexCandidate's
    #    predicates.
    # 7. unsupported_construct: the key expressions and the predicate,
    #    taken as a SELECT's target list and WHERE clause, use a construct
    #    SupportedSql refuses. FunctionCalls, which the next check relies
    #    on, is only right for what SupportedSql lists. A row comparison,
    #    which SupportedSql allows for keyset pagination, is refused here
    #    too as RowExpr: no index predicate needs one.
    # 8. volatile_function (or bad_search_path): the volatility VolatilityCheck, run
    #    on that SELECT, finds a volatile function, operator, or cast. Its
    #    conservative rule holds here too: a call is refused if any
    #    function it could resolve to is volatile.
    # 9. deparse_mismatch: the DDL, with its name, IF NOT EXISTS, and
    #    comments dropped, doesn't parse back to the same tree when pg_query
    #    deparses it (see Deparse).
    #
    # What it doesn't catch:
    # - A STABLE function in a key expression or the predicate, such as
    #   now() or date_trunc on a timestamptz. Postgres requires IMMUTABLE,
    #   but checking that from the catalog alone would take Postgres's full
    #   type resolution: =, <, and the other comparison operators each have
    #   STABLE forms, such as date = timestamptz, so the conservative rule
    #   would refuse nearly every predicate. Postgres refuses a STABLE
    #   function when it builds the index, and HypoPG does when it makes a
    #   hypothetical one, so such DDL fails there instead of here. A STABLE
    #   function has no side effects, so nothing unsafe runs.
    # - It trusts provolatile, so a function mislabeled STABLE or IMMUTABLE
    #   isn't caught, the same as the rewrite check. Attribute notation,
    #   (orders.f), is checked like f(orders), and a cast to a domain
    #   counts its CHECK constraints' functions (see VolatilityCheck).
    # - Whether the columns exist, and whether the index method and
    #   operator classes fit them. Postgres checks those when the index is
    #   made.
    #
    # Every failure raises Error, with the rule and a message naming only
    # the rule and shape-class names: tables, schemas, functions,
    # operators, and node types. It never quotes the DDL, whose predicate
    # can hold literals, and it has no cause.
    #
    # On success it returns Accepted: the DDL without its name, IF NOT
    # EXISTS (which needs a name), or comments, as pg_query deparses it;
    # that SQL's parse; and the table, so later steps name each index
    # themselves.
    module IndexDdlCheck
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end

        # The same rule and message as another check's error, which follows
        # the same "rule: detail" form.
        def self.from(error) = new(error.rule, error.message.delete_prefix("#{error.rule}: "))
      end

      Accepted = Data.define(:sql, :parse, :table)

      # Each refused option: its rule, what it's called in SQL, and whether
      # the statement uses it.
      REFUSED_OPTIONS = [
        ["concurrently", "CONCURRENTLY", lambda(&:concurrent)],
        ["unique", "UNIQUE", lambda(&:unique)],
        ["nulls_not_distinct", "NULLS NOT DISTINCT", lambda(&:nulls_not_distinct)],
        ["tablespace", "TABLESPACE", ->(stmt) { !stmt.table_space.empty? }],
        ["on_only", "ON ONLY", ->(stmt) { !stmt.relation.inh }],
        ["storage_options", "WITH (...)", ->(stmt) { !stmt.options.empty? }]
      ].freeze

      module_function

      def check(sql, tables, settings, connection)
        stmt = index_stmt(parse(sql))
        options!(stmt)
        table = table!(stmt.relation, tables)
        forbidden!(stmt)
        volatility!(probe(stmt), settings, connection)
        accepted(stmt, table)
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("unparsable", ParserVersion.unparsable("the index DDL doesn't parse")), cause: nil
      end

      def index_stmt(parse)
        stmts = parse.tree.stmts
        raise Error.new("not_create_index", "#{stmts.size} statements, not one") unless stmts.size == 1

        stmt = stmts.first.stmt
        return stmt.index_stmt if stmt.node == :index_stmt

        raise Error.new("not_create_index", "#{type_name(stmt.inner)}, not IndexStmt")
      end

      def type_name(node) = node.class.name.split("::").last

      def options!(stmt)
        REFUSED_OPTIONS.each do |rule, name, used|
          raise Error.new(rule, "#{name} isn't allowed") if used.call(stmt)
        end
      end

      def table!(relation, tables)
        raise Error.new("unqualified_table", "#{relation.relname} isn't schema qualified") if relation.schemaname.empty?

        table = TableName.new(schema: relation.schemaname, name: relation.relname)
        raise Error.new("unknown_relation", "#{table} is named with a database") unless relation.catalogname.empty?
        raise Error.new("unknown_relation", "#{table} isn't a table the query uses") unless tables.include?(table)

        table
      end

      def forbidden!(stmt)
        [["a key expression", expressions(stmt)], ["the predicate", [stmt.where_clause].compact]].each do |where, nodes|
          problem = nodes.lazy.filter_map { |node| first_forbidden(node) }.first
          raise Error.new("forbidden_in_index", "#{where} uses #{problem}") if problem
        end
      end

      # What IndexSql.forbidden finds first in the tree under node, in tree
      # order, or nil.
      def first_forbidden(node)
        case node
        when Google::Protobuf::RepeatedField then node.lazy.filter_map { |child| first_forbidden(child) }.first
        when Google::Protobuf::MessageExts
          IndexSql.forbidden(node) ||
            node.class.descriptor.lazy.filter_map { |field| first_forbidden(field.get(node)) }.first
        end
      end

      # The expressions of the key and INCLUDE columns. A plain column has
      # none.
      def expressions(stmt)
        (stmt.index_params + stmt.index_including_params).map { |param| param.index_elem.expr }.compact
      end

      # The key expressions and the predicate as a SELECT's target list and
      # WHERE clause, the shape SupportedSql and VolatilityCheck read. It's
      # built as a tree, so the parse has no text of its own.
      def probe(stmt)
        targets = expressions(stmt).map { |expr| PgQuery::Node.from(PgQuery::ResTarget.new(val: expr)) }
        select = PgQuery::SelectStmt.new(target_list: targets, where_clause: stmt.where_clause,
                                         limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        tree = PgQuery::ParseResult.new(stmts: [PgQuery::RawStmt.new(stmt: PgQuery::Node.from(select))])
        PgQuery::ParserResult.new("", tree)
      end

      def volatility!(probe, settings, connection)
        raise Error.new("unsupported_construct", "RowExpr") if row?(probe.tree)

        VolatilityCheck.check_parse(probe, settings, connection)
      rescue SupportedSql::Error, VolatilityCheck::Error => e
        raise Error.from(e), cause: nil
      end

      def row?(node)
        case node
        when PgQuery::RowExpr then true
        when Google::Protobuf::RepeatedField then node.any? { |child| row?(child) }
        when Google::Protobuf::MessageExts then node.class.descriptor.any? { |field| row?(field.get(node)) }
        else false
        end
      end

      # The statement without its name or IF NOT EXISTS, deparsed.
      def accepted(stmt, table)
        stmt.idxname = ""
        stmt.if_not_exists = false
        wrapped = PgQuery::ParseResult.new(stmts: [PgQuery::RawStmt.new(stmt: PgQuery::Node.from(stmt))])
        parse = Deparse.faithful_parse(wrapped)
        Accepted.new(sql: parse.query, parse:, table:)
      rescue Deparse::Error => e
        raise Error.from(e), cause: nil
      end
    end
  end
end
