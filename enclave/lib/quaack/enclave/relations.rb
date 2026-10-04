# frozen_string_literal: true

require "pg_query"
require_relative "parser_version"
require_relative "deparse"
require_relative "from_functions"
require_relative "relation_qualifier"
require_relative "supported_sql"
require_relative "table_name"

module Quaack
  module Enclave
    # DESIGN.md's qualify: list the relations the query uses, and abort unless every
    # one is a plain table (relkind r).
    #
    #   Relations.check(sql, settings, connection)
    #   # => Result(sql: "SELECT ... FROM public.orders", parse: PgQuery::ParseResult,
    #   #           relations: [TableName(public.orders)])
    #   # or raises Error "view_relation: public.order_view is a view (relkind v), not a plain table"
    #
    # This is the one entry point for the relation check. The inbound check
    # for rewrite candidates (20260922-10) is meant to call it too, and
    # doesn't yet.
    #
    # The inputs are the ones RelationQualifier takes: the query text,
    # qualified or not, the Settings hash from the input plan's EXPLAIN
    # (SETTINGS), or nil, and a PG connection to the production database.
    # Until the production connection (20260922-16) lands, the caller passes
    # one in. Only the catalog is read, with plain SELECTs.
    #
    # The query is qualified with RelationQualifier, so its names resolve
    # the same way, through the same search path, and a reference to a CTE
    # isn't a relation. Every RangeVar left with a schema is a relation.
    # SupportedSql only lets a RangeVar go where a FROM item goes, so that
    # covers FROM, joins, subqueries, CTE bodies, LATERAL, set operations,
    # and sublinks anywhere in the query. Each relation is listed once, in
    # the order the query's text first names it.
    #
    # Each relation's relkind is read from pg_class, in its own schema.
    # Anything but r is refused, with a rule for its kind, so the error line
    # that leaves the enclave says what kind it was: view_relation (v),
    # matview_relation (m), partitioned_relation (p), foreign_relation (f),
    # sequence_relation (S), composite_type_relation (c), toast_relation
    # (t), index_relation (i and I), and not_a_table for any other. A
    # partition is relkind r, so a query that names one directly passes.
    #
    # A plain table scans its inheritance children too, unless the query
    # says ONLY. So unless every reference to it says ONLY, each of its
    # descendants, at any depth, must be a plain table as well, or the
    # query is refused with the rule for the first one that isn't. Only
    # the relations the query names are listed, not their descendants.
    #
    # When several relations aren't plain tables, the first the query's
    # text names wins.
    #
    # A function in FROM that isn't pg_catalog's is refused as
    # user_function_in_from (see FromFunctions).
    #
    # The other refusals: parse_error, unsupported_construct, bad_search_path
    # (the Settings' search_path doesn't read), unknown_relation (a name
    # doesn't resolve, or a qualified one doesn't exist), and
    # deparse_mismatch (see Deparse).
    #
    # Every refusal raises Error, with the rule and a message naming only
    # the rule and shape-class names: relations, schemas, node types, and
    # the search path. It never quotes the query, and it has no cause.
    # ErrorFilter sends only the rule out of the enclave.
    module Relations
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

      Result = Data.define(:sql, :parse, :relations)

      # Each relkind but r: its rule, and how a message names it.
      KINDS = {
        "v" => ["view_relation", "a view"],
        "m" => ["matview_relation", "a materialized view"],
        "p" => ["partitioned_relation", "a partitioned table"],
        "f" => ["foreign_relation", "a foreign table"],
        "S" => ["sequence_relation", "a sequence"],
        "c" => ["composite_type_relation", "a composite type"],
        "t" => ["toast_relation", "a toast table"],
        "i" => ["index_relation", "an index"],
        "I" => ["index_relation", "a partitioned index"]
      }.freeze

      OTHER = ["not_a_table", "a relation"].freeze

      # The relation in schema $1 named $2, and when $3 is true, every
      # inheritance descendant of it, at any depth. Each row is a schema,
      # name, and relkind. The relation comes first, and each descendant
      # follows its parent, since the rows are ordered by the path of oids
      # that reaches them.
      RELKIND_SQL = <<~SQL
        WITH RECURSIVE tree (oid, path) AS (
          SELECT c.oid, ARRAY[c.oid]
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = $1 AND c.relname = $2
          UNION ALL
          SELECT i.inhrelid, tree.path || i.inhrelid
          FROM tree
          JOIN pg_catalog.pg_inherits i ON i.inhparent = tree.oid
          WHERE $3::boolean
        )
        SELECT n.nspname, c.relname, c.relkind
        FROM tree
        JOIN pg_catalog.pg_class c ON c.oid = tree.oid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        ORDER BY tree.path
      SQL

      module_function

      def check(sql, settings, connection)
        parse = parse(sql)
        supported!(parse)
        qualified = qualify(parse.tree, settings, connection)
        functions!(parse.tree, settings, connection)
        relations = tables(parse.tree)
        relations.each { |table, inherits| plain_table!(table, inherits, connection) }
        Result.new(sql: qualified.query, parse: qualified, relations: relations.keys)
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("parse_error", ParserVersion.unparsable("the query doesn't parse")), cause: nil
      end

      def supported!(parse)
        SupportedSql.check!(parse)
      rescue SupportedSql::Error => e
        raise Error.from(e), cause: nil
      end

      # Qualifies the tree in place, the way RelationQualifier.qualify does,
      # and returns the qualified SQL's own parse. The tree keeps where in
      # the query's text each relation was, which tables needs. The search
      # path is read first, so a bad one gets its own rule rather than
      # unknown_relation.
      def qualify(tree, settings, connection)
        rule = "bad_search_path"
        RelationQualifier.search_path(settings, connection)
        rule = "unknown_relation"
        RelationQualifier.qualify_tree(tree, settings, connection)
        Deparse.faithful_parse(tree)
      rescue RelationQualifier::Error => e
        raise Error.new(rule, e.message), cause: nil
      rescue Deparse::Error => e
        raise Error.from(e), cause: nil
      end

      # Each relation in a qualified tree, once, in the order the query's
      # text first names it, and whether any reference to it takes in its
      # inheritance descendants (no ONLY). The tree's own order isn't the
      # text's: it keeps WITH after FROM, and OFFSET before LIMIT. A
      # RangeVar with no schema left is a reference to a CTE.
      def tables(tree)
        ranges = range_vars(tree).reject { |range| range.schemaname.empty? }.sort_by(&:location)
        ranges.each_with_object({}) do |range, found|
          table = TableName.new(schema: range.schemaname, name: range.relname)
          found[table] = found.fetch(table, false) || range.inh
        end
      end

      def functions!(tree, settings, connection)
        return unless FromFunctions.user_function?(tree, settings, connection)

        raise Error.new("user_function_in_from", "a function in FROM isn't in pg_catalog"), cause: nil
      end

      def plain_table!(table, inherits, connection)
        rows = connection.exec_params(RELKIND_SQL, [table.schema, table.name, inherits.to_s]).values
        (_, _, relkind), *descendants = rows
        raise Error.new("unknown_relation", "#{table} doesn't exist") unless relkind

        refuse!(relkind, "#{table} is") unless relkind == "r"
        descendants.each do |schema, name, kind|
          next if kind == "r"

          refuse!(kind, "#{table} has an inheritance descendant, #{TableName.new(schema:, name:)}, that is")
        end
      end

      # Refuses a relation of relkind, which isn't r. Every refusal for a
      # relkind comes through here.
      def refuse!(relkind, subject)
        rule, kind = KINDS.fetch(relkind, OTHER)
        raise Error.new(rule, "#{subject} #{kind} (relkind #{relkind}), not a plain table")
      end

      # Every RangeVar in the tree, in tree order.
      def range_vars(node, found = [])
        case node
        when PgQuery::RangeVar then found << node
        when Google::Protobuf::RepeatedField then node.each { |child| range_vars(child, found) }
        when PgQuery::Node then range_vars(node.inner, found)
        when Google::Protobuf::MessageExts
          node.class.descriptor.each { |field| range_vars(field.get(node), found) }
        end
        found
      end
    end
  end
end
