# frozen_string_literal: true

require "pg_query"
require "strscan"
require_relative "deparse"
require_relative "supported_sql"
require_relative "table_name"

module Quaack
  module Enclave
    # README step 1: rewrite the query so every relation names its schema,
    # and search_path never matters again.
    #
    #   RelationQualifier.qualify(sql, settings, connection)
    #   # => Result(sql: "SELECT ... FROM public.orders", parse: PgQuery::ParserResult,
    #   #           resolved: {"orders" => TableName})
    #
    # Until input intake (20260922-13) lands, the inputs are plain values:
    # the query text, the Settings hash from the input plan's EXPLAIN
    # (SETTINGS), or nil, and a PG connection to the production database.
    # The only thing read from the connection is the catalog, with plain
    # SELECTs, and the session's own search_path is never changed.
    #
    # A relation that names its schema keeps it. A reference to a CTE whose
    # name reaches it isn't a relation, so it's left alone: a CTE's name
    # reaches the rest of its statement, including subqueries, and later
    # CTEs in the same WITH. Under WITH RECURSIVE it reaches every CTE
    # there, itself included.
    #
    # The query must use only what SupportedSql lists, so it's one SELECT
    # with no locking clause. Anything else raises SupportedSql::Error.
    #
    # Every other name is resolved the way Postgres resolved it for the
    # session that made the plan, using the search_path in Settings. EXPLAIN
    # (SETTINGS) lists only settings that differ from the default, so a
    # missing search_path means the default, "$user", public. Resolution
    # follows Postgres: pg_catalog comes first unless the path lists it
    # somewhere; "$user" is the connecting role's name; and a schema that
    # doesn't exist, or that the connecting role has no USAGE on, is
    # skipped. The first remaining schema with a pg_class entry of that name
    # wins, whatever its relkind. Step 3a checks the relkind.
    #
    # The result's sql is the rewritten query, deparsed by pg_query, parse
    # is that SQL's own parse, and resolved maps each name that had no
    # schema to the table it now names. The deparser can write SQL that
    # means something else, so the SQL must parse back to the rewritten
    # tree. If it doesn't, Deparse::Error (rule deparse_mismatch) is raised.
    #
    # Anything that can't be done raises Error, naming the rule it broke.
    # Relation and schema names are shape-class, so messages may name them,
    # but a message never quotes the query: pg_query's parse errors quote
    # the text near the error, which can be a literal, so they're replaced
    # rather than wrapped.
    module RelationQualifier
      class Error < StandardError; end

      Result = Data.define(:sql, :parse, :resolved)

      DEFAULT_SEARCH_PATH = '"$user", public'

      # The schemas of path, in order, that exist and that the connecting
      # role may use, each with its place in the path.
      RESOLVE_SQL = <<~SQL
        SELECT n.nspname
        FROM unnest($1::text[]) WITH ORDINALITY AS path(nspname, position)
        JOIN pg_catalog.pg_namespace n ON n.nspname = path.nspname
        JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = $2
        WHERE pg_catalog.has_schema_privilege(n.oid, 'USAGE')
        ORDER BY path.position
        LIMIT 1
      SQL

      module_function

      def qualify(sql, settings, connection)
        parse = parse(sql)
        unqualified = []
        collect(parse.tree, [], unqualified)
        path = unqualified.empty? ? [] : search_path(settings, connection)
        resolved = {}
        unqualified.each do |range|
          table = resolved[range.relname] ||= resolve(range.relname, path, connection)
          range.schemaname = table.schema
        end
        qualified = Deparse.faithful_parse(parse.tree)
        Result.new(sql: qualified.query, parse: qualified, resolved:)
      end

      # The parse, once SupportedSql has checked it.
      def parse(sql)
        parse = begin
          PgQuery.parse(sql)
        rescue PgQuery::ParseError
          raise Error, "the query doesn't parse", cause: nil
        end
        SupportedSql.check!(parse)
        parse
      end

      # Every RangeVar with no schema that isn't a reference to a CTE in
      # scope.
      def collect(node, ctes, found)
        case node
        when PgQuery::RangeVar then found << node if unqualified?(node, ctes)
        when Google::Protobuf::RepeatedField then node.each { |child| collect(child, ctes, found) }
        when Google::Protobuf::MessageExts then collect_message(node, ctes, found)
        end
      end

      def unqualified?(range, ctes) = range.schemaname.empty? && !ctes.include?(range.relname)

      def collect_message(node, ctes, found)
        with = node.class.descriptor.lookup("with_clause")&.get(node)
        names = with ? collect_ctes(with, ctes, found) : []
        node.class.descriptor.each do |field|
          next if field.name == "with_clause"

          collect(field.get(node), ctes + names, found)
        end
      end

      # Walks each CTE's body with the names that reach it, and returns the
      # names.
      def collect_ctes(with, ctes, found)
        names = with.ctes.map { |cte| cte.common_table_expr.ctename }
        with.ctes.each_with_index do |cte, i|
          collect(cte.common_table_expr, ctes + (with.recursive ? names : names.first(i)), found)
        end
        names
      end

      # The schemas to search, in order, as Postgres builds them.
      def search_path(settings, connection)
        raw = settings&.fetch("search_path", nil) || DEFAULT_SEARCH_PATH
        user = connection.exec("SELECT current_user").getvalue(0, 0)
        schemas = split_identifiers(raw).map { |name| name == "$user" ? user : name }
        schemas.include?("pg_catalog") ? schemas : ["pg_catalog", *schemas]
      end

      # Postgres's SplitIdentifierString: a comma-separated list where each
      # entry is a double-quoted identifier, with "" for a quote, or an
      # unquoted one folded to lower case. Each is cut to NAMEDATALEN - 1
      # bytes, without splitting a character, as Postgres cuts it.
      def split_identifiers(raw)
        scanner = StringScanner.new(raw)
        names = []
        loop do
          scanner.skip(/\s*/)
          names << truncate(next_identifier(scanner, raw))
          scanner.skip(/\s*/)
          break if scanner.eos?
          raise Error, "search_path #{raw} isn't a list of identifiers" unless scanner.skip(/,/)
        end
        names
      end

      def next_identifier(scanner, raw)
        if scanner.skip(/"/)
          quoted = scanner.scan(/(?:[^"]|"")*/)
          raise Error, "search_path #{raw} has an unterminated quote" unless scanner.skip(/"/)

          quoted.gsub('""', '"')
        else
          unquoted = scanner.scan(/[^,\s]+/)
          raise Error, "search_path #{raw} has an empty entry" unless unquoted

          unquoted.tr("A-Z", "a-z")
        end
      end

      MAX_IDENTIFIER_BYTES = 63

      def truncate(name)
        name.bytesize > MAX_IDENTIFIER_BYTES ? name.byteslice(0, MAX_IDENTIFIER_BYTES).scrub("") : name
      end

      # A text[] literal with every element quoted, so the enclave needn't
      # load the pg gem to encode one.
      def text_array(names)
        elements = names.map { |name| %("#{name.gsub(/["\\]/) { |char| "\\#{char}" }}") }
        "{#{elements.join(",")}}"
      end

      def resolve(name, path, connection)
        rows = connection.exec_params(RESOLVE_SQL, [text_array(path), name])
        return TableName.new(schema: rows.getvalue(0, 0), name:) if rows.ntuples == 1

        raise Error, "relation #{name} isn't schema qualified, and no schema in the search path " \
                     "(#{path.join(", ")}) has it"
      end
    end
  end
end
