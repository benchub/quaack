# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "relation_qualifier"
require_relative "supported_sql"
require_relative "table_name"

module Quaack
  module Enclave
    # README 3a: list the relations the query uses, and abort unless every
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
    # the order the query first names it.
    #
    # Each relation's relkind is read from pg_class, in its own schema.
    # Anything but r is refused, with a rule for its kind, so the error line
    # that leaves the enclave says what kind it was: view_relation (v),
    # matview_relation (m), partitioned_relation (p), foreign_relation (f),
    # sequence_relation (S), composite_type_relation (c), toast_relation
    # (t), index_relation (i and I), and not_a_table for any other. A
    # partition is relkind r, so a query that names one directly passes.
    # When several aren't plain tables, the first the query names wins.
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

      RELKIND_SQL = <<~SQL
        SELECT c.relkind
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = $1 AND c.relname = $2
      SQL

      module_function

      def check(sql, settings, connection)
        supported!(parse(sql))
        qualified = qualify(sql, settings, connection)
        relations = tables(qualified.parse)
        relations.each { |table| plain_table!(table, connection) }
        Result.new(sql: qualified.sql, parse: qualified.parse, relations:)
      end

      # The rule for a relation of relkind, which isn't r.
      def rule_for(relkind) = KINDS.fetch(relkind, OTHER).first

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("parse_error", "the query doesn't parse"), cause: nil
      end

      def supported!(parse)
        SupportedSql.check!(parse)
      rescue SupportedSql::Error => e
        raise Error.from(e), cause: nil
      end

      # The query qualified, as RelationQualifier qualifies it. The search
      # path is read first, so a bad one gets its own rule rather than
      # unknown_relation.
      def qualify(sql, settings, connection)
        rule = "bad_search_path"
        RelationQualifier.search_path(settings, connection)
        rule = "unknown_relation"
        RelationQualifier.qualify(sql, settings, connection)
      rescue RelationQualifier::Error => e
        raise Error.new(rule, e.message), cause: nil
      rescue Deparse::Error => e
        raise Error.from(e), cause: nil
      end

      # Each relation in a qualified parse, once, in tree order. A RangeVar
      # with no schema left is a reference to a CTE.
      def tables(parse)
        ranges = range_vars(parse.tree).reject { |range| range.schemaname.empty? }
        ranges.map { |range| TableName.new(schema: range.schemaname, name: range.relname) }.uniq
      end

      def plain_table!(table, connection)
        rows = connection.exec_params(RELKIND_SQL, [table.schema, table.name])
        raise Error.new("unknown_relation", "#{table} doesn't exist") if rows.ntuples.zero?

        relkind = rows.getvalue(0, 0)
        return if relkind == "r"

        rule, kind = KINDS.fetch(relkind, OTHER)
        raise Error.new(rule, "#{table} is #{kind} (relkind #{relkind}), not a plain table")
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
