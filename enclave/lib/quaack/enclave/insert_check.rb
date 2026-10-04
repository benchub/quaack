# frozen_string_literal: true

require "pg_query"
require_relative "parser_version"
require_relative "deparse"
require_relative "insert_values"
require_relative "table_name"

module Quaack
  module Enclave
    # The inbound check for counterexamples's inserts (DESIGN.md, "What goes into the
    # enclave"). The LLM writes them to fill a fixture, so they're
    # untrusted, and the arena runner accepts any single InsertStmt. This
    # check is the real guard, and runs on each insert before anything
    # else does.
    #
    #   InsertCheck.check(sql, tables, settings, connection)
    #   # => Accepted(sql: "INSERT INTO sales.items (id, sku) VALUES (1, 'a'), (2, 'b')",
    #   #             parse: PgQuery::ParseResult, table: TableName)
    #   # or raises Error "unknown_relation: sales.refunds isn't a table in the subset schema"
    #
    # The inputs:
    # - sql, the insert's text.
    # - tables, the TableNames of the schema-dump subset schema's tables.
    # - settings, the Settings hash from the input plan's EXPLAIN
    #   (SETTINGS), or nil, as RelationQualifier takes it. Its search_path
    #   is used only to look up unqualified function and operator names.
    # - connection, a PG connection to the production database. Only the
    #   catalog is read, with plain SELECTs.
    #
    # A plain insert is INSERT INTO <subset table> (<columns>) VALUES (...),
    # (...). The checks run in this order, and the first one that fails
    # wins:
    #
    # 1. unparsable: pg_query can't parse it. pg_query's own message quotes
    #    the text near the error, so it's replaced, not wrapped.
    # 2. not_insert: it isn't exactly one statement, or that statement
    #    isn't an INSERT.
    # 3. with, on_conflict, and returning, in that order: it uses WITH, ON
    #    CONFLICT, or RETURNING. OVERRIDING SYSTEM VALUE and OVERRIDING USER
    #    VALUE are allowed (task 20260927-24), so a counterexample can set a
    #    GENERATED ALWAYS identity key, as rewrite-test's fixture rows do. The
    #    inserts load only into the throwaway arena.
    # 4. missing_columns: it has no column list, DEFAULT VALUES included.
    # 5. insert_select: its rows aren't a bare VALUES list, as with INSERT
    #    ... SELECT, or VALUES with ORDER BY, LIMIT, or a set operation.
    # 6. alias: the table has an alias.
    # 7. unqualified_table: the table has no schema. It isn't resolved
    #    through the search path.
    # 8. unknown_relation: the table isn't one of tables, or is named with
    #    a database in front.
    # 9. unknown_column: a column is subscripted or has a field, or isn't a
    #    live user column of the table in the catalog.
    # 10. not_plain_value: a value is something other than a constant
    #     (NULL included), a cast, DEFAULT (only as a whole value), an
    #     ARRAY[...], or a plain function call whose arguments are all of
    #     those but DEFAULT. So no subquery, column, $n, operator, CASE,
    #     named argument, or aggregate or window syntax. A negative number
    #     is a constant: the parser folds the minus in.
    # 11. not_immutable (or bad_search_path): a function call could
    #     resolve to a function that isn't IMMUTABLE. As in the volatility check,
    #     every function of that name that could take that many arguments
    #     counts, in the named schema or else every schema of the plan's
    #     search path. That refuses now(), random(), nextval, set_config,
    #     and the advisory locks.
    # 12. volatile_function: the volatility VolatilityCheck, run on the values as a
    #     SELECT's target list, finds a volatile cast. A cast is held only
    #     to the volatility rule, not to IMMUTABLE, since the input functions of
    #     date, timestamptz, and the like are STABLE, and '2024-01-01'::date
    #     is what fixtures are made of.
    # 13. deparse_mismatch: the insert doesn't parse back to the same tree
    #     when pg_query deparses it (see Deparse).
    #
    # It trusts provolatile, as the other checks do. Whether a value fits
    # its column, and whether a row has as many values as columns, are left
    # to Postgres when the insert runs.
    #
    # Every failure raises Error, with the rule and a message naming only
    # the rule and shape-class names: tables, schemas, columns, functions,
    # and node types. It never quotes the insert, whose values are
    # literals, and it has no cause.
    #
    # On success it returns Accepted: the insert as pg_query deparses it,
    # which drops its comments; that SQL's parse; and the table.
    module InsertCheck
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

      # Each refused form: its rule, what it's called in SQL, and whether
      # the statement uses it.
      REFUSED_FORMS = [
        ["with", "WITH", ->(stmt) { !stmt.with_clause.nil? }],
        ["on_conflict", "ON CONFLICT", ->(stmt) { !stmt.on_conflict_clause.nil? }],
        ["returning", "RETURNING", ->(stmt) { !stmt.returning_list.empty? }]
      ].freeze

      # A SelectStmt that's nothing but a VALUES list, once the list is
      # taken out.
      BARE_VALUES = PgQuery::SelectStmt.new(limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)

      # The live user columns of a table.
      COLUMNS_SQL = <<~SQL
        SELECT a.attname
        FROM pg_catalog.pg_attribute a
        JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
      SQL

      module_function

      def check(sql, tables, settings, connection)
        stmt = insert_stmt(parse(sql))
        forms!(stmt)
        rows = rows!(stmt)
        table = table!(stmt.relation, tables)
        columns!(stmt.cols, table, connection)
        values!(rows, settings, connection)
        accepted(stmt, table)
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("unparsable", ParserVersion.unparsable("the insert doesn't parse")), cause: nil
      end

      def insert_stmt(parse)
        stmts = parse.tree.stmts
        raise Error.new("not_insert", "#{stmts.size} statements, not one") unless stmts.size == 1

        stmt = stmts.first.stmt
        return stmt.insert_stmt if stmt.node == :insert_stmt

        raise Error.new("not_insert", "#{type_name(stmt.inner)}, not InsertStmt")
      end

      def type_name(node) = node.class.name.split("::").last

      def forms!(stmt)
        REFUSED_FORMS.each do |rule, name, used|
          raise Error.new(rule, "#{name} isn't allowed") if used.call(stmt)
        end
      end

      # The VALUES rows, each an Array of value nodes.
      def rows!(stmt)
        raise Error.new("missing_columns", "the insert must list its columns") if stmt.cols.empty?

        select = stmt.select_stmt&.select_stmt
        raise Error.new("insert_select", "the rows must be a VALUES list") unless bare_values?(select)

        select.values_lists.map { |row| row.list.items.to_a }
      end

      # Whether select is a VALUES list with nothing else, once the list is
      # taken out of a copy.
      def bare_values?(select)
        return false if select.nil?

        bare = PgQuery::SelectStmt.decode(PgQuery::SelectStmt.encode(select))
        bare.values_lists.clear
        bare == BARE_VALUES
      end

      def table!(relation, tables)
        table = name!(relation)
        raise Error.new("unknown_relation", "#{table} is named with a database") unless relation.catalogname.empty?
        return table if tables.include?(table)

        raise Error.new("unknown_relation", "#{table} isn't a table in the subset schema")
      end

      def name!(relation)
        raise Error.new("alias", "an alias isn't allowed") if relation.alias
        raise Error.new("unqualified_table", "#{relation.relname} isn't schema qualified") if relation.schemaname.empty?

        TableName.new(schema: relation.schemaname, name: relation.relname)
      end

      def columns!(cols, table, connection)
        known = connection.exec_params(COLUMNS_SQL, [table.schema, table.name]).column_values(0)
        cols.each do |col|
          target = col.res_target
          unless target.indirection.empty?
            raise Error.new("unknown_column", "#{target.name} is subscripted or has a field")
          end
          raise Error.new("unknown_column", "#{table} has no column #{target.name}") unless known.include?(target.name)
        end
      end

      def values!(rows, settings, connection)
        InsertValues.check(rows, settings, connection)
      rescue InsertValues::Error => e
        raise Error.from(e), cause: nil
      end

      def accepted(stmt, table)
        wrapped = PgQuery::ParseResult.new(stmts: [PgQuery::RawStmt.new(stmt: PgQuery::Node.from(stmt))])
        parse = Deparse.faithful_parse(wrapped)
        Accepted.new(sql: parse.query, parse:, table:)
      rescue Deparse::Error => e
        raise Error.from(e), cause: nil
      end
    end
  end
end
