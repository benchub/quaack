# frozen_string_literal: true

require "pg_query"
require_relative "parser_version"
require_relative "deparse"
require_relative "name_qualifier"
require_relative "relation_qualifier"
require_relative "supported_sql"
require_relative "table_name"
require_relative "volatility_check"

module Quaack
  module Enclave
    # The inbound check for rewrite candidates (DESIGN.md, "What goes into the
    # enclave"). A candidate comes from the LLM in llm-rewrites or from an
    # operator in operator-rewrites, so it's untrusted. This check runs on it before
    # anything else does.
    #
    #   RewriteCandidateCheck.check(sql, original, settings, connection)
    #   # => Accepted(sql: "SELECT ... FROM public.orders WHERE ... $1", parse: PgQuery::ParseResult)
    #   # or raises Error "not_a_table: public.order_view has relkind v, not r"
    #
    # The inputs:
    # - sql, the candidate's text, written with the original's $n
    #   placeholders in place of literals.
    # - original, what the check needs to know about the original query.
    #   Until qualify (20260922-17) and redact (20260922-23) land, it's the stand-in
    #   Original: the relations the original uses, as TableNames, and how
    #   many placeholders its redacted form has.
    # - settings, the Settings hash from the input plan's EXPLAIN
    #   (SETTINGS), or nil, as RelationQualifier takes it.
    # - connection, a PG connection to the racetrack (RewriteCheck). Only the
    #   catalog is read, with plain SELECTs.
    #
    # The checks run in this order, and the first one that fails wins:
    #
    # 1. unparsable: pg_query can't parse it. pg_query's own message quotes
    #    the text near the error, so it's replaced, not wrapped.
    # 2. unsupported_construct: SupportedSql refuses it. That covers
    #    everything DESIGN.md names: it must be exactly one SELECT, with no
    #    data-modifying CTE, no SELECT INTO, and no locking clause.
    # 3. bad_placeholder: it uses a $n outside $1 to $N, where N is the
    #    original's count. Literals of its own, such as LIMIT 1 or
    #    COALESCE(x, 0), are allowed. The LLM only saw the redacted query,
    #    and a literal in a candidate flows into the enclave, not out of it,
    #    so it can't leak anything.
    # 4. Relations. Each is qualified the way RelationQualifier qualifies
    #    the original, with the same Settings. bad_search_path if the
    #    Settings' search_path doesn't read, and unknown_relation if a
    #    relation doesn't resolve, doesn't exist, or isn't one the original
    #    uses. A candidate may leave out relations the original uses, since
    #    a rewrite can eliminate a join. not_a_table if a relation isn't a
    #    plain table (relkind r), since a view's body can call a volatile
    #    function that the volatility check, below, never sees.
    #    deparse_mismatch if the qualified candidate, as pg_query deparses
    #    it, doesn't parse back to the tree it came from (see Deparse). So
    #    Accepted's parse is the candidate's own parse with schemas added,
    #    and checks 2 and 3 hold for it without being run again.
    # 5. volatile_function (or bad_search_path): volatility's VolatilityCheck
    #    finds a volatile function. That refuses set_config, advisory
    #    locks, lo_import, nextval, and the rest, whose effects outlive the
    #    arena's transaction or change the session.
    #
    # What it doesn't catch, tracked in 20260923-35: a STABLE function
    # that reads tables outside the original's set, such as table_to_xml
    # or a STABLE SQL function, is accepted. The rows it reads stay in the
    # enclave. The check also trusts provolatile, so a function mislabeled
    # STABLE isn't caught.
    #
    # Every failure raises Error, with the rule and a message naming only
    # the rule and shape-class names: relations, schemas, functions, node
    # types, and placeholder numbers. It never quotes the candidate, and it
    # has no cause.
    #
    # On success it returns Accepted: the candidate qualified and deparsed
    # by pg_query, which drops its comments, and that SQL's parse.
    module RewriteCandidateCheck
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

      # A stand-in for what qualify and redact will give: the TableNames the original
      # uses, and the number of placeholders in its redacted form.
      Original = Data.define(:relations, :placeholders)

      Accepted = Data.define(:sql, :parse)

      RELKIND_SQL = <<~SQL
        SELECT c.relkind
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        WHERE n.nspname OPERATOR(pg_catalog.=) $1 AND c.relname OPERATOR(pg_catalog.=) $2
      SQL

      module_function

      def check(sql, original, settings, connection)
        parse = parse(sql)
        supported!(parse)
        placeholders!(parse, original.placeholders)
        accepted = qualify(sql, settings, connection)
        relations!(accepted.parse, original.relations, connection)
        volatility!(accepted.sql, settings, connection)
        accepted
      end

      def parse(sql)
        PgQuery.parse(sql)
      rescue PgQuery::ParseError
        raise Error.new("unparsable", ParserVersion.unparsable("the candidate doesn't parse")), cause: nil
      end

      def supported!(parse)
        SupportedSql.check!(parse)
      rescue SupportedSql::Error => e
        raise Error.from(e), cause: nil
      end

      def placeholders!(parse, count)
        bad = nodes(parse.tree, PgQuery::ParamRef).find { |param| !param.number.between?(1, count) }
        return unless bad

        why = if count.zero? then "isn't allowed, since the original has no placeholders"
              else "isn't one of the original's $1 to $#{count}"
              end
        raise Error.new("bad_placeholder", "$#{bad.number} #{why}")
      end

      # The candidate qualified, and its parse. The search path is read
      # first, so a bad one gets its own rule rather than unknown_relation.
      def qualify(sql, settings, connection)
        rule = "bad_search_path"
        path = RelationQualifier.search_path(settings, connection)
        rule = "unknown_relation"
        qualified = qualified_parse(sql, path, settings, connection)
        Accepted.new(sql: qualified.query, parse: qualified)
      rescue RelationQualifier::Error => e
        raise Error.new(rule, e.message), cause: nil
      rescue Deparse::Error, NameQualifier::Error => e
        raise Error.from(e), cause: nil
      end

      # The candidate's parse with its relations qualified, as
      # RelationQualifier.qualify does, and its other names (NameQualifier).
      def qualified_parse(sql, path, settings, connection)
        tree = RelationQualifier.parse(sql).tree
        RelationQualifier.qualify_tree(tree, settings, connection)
        NameQualifier.qualify!(tree, path, connection)
        Deparse.faithful_parse(tree)
      end

      def relations!(parse, allowed, connection)
        used = tables(parse)
        unknown = used.find { |table| !allowed.include?(table) }
        raise Error.new("unknown_relation", "#{unknown} isn't a relation the original uses") if unknown

        used.each { |table| plain_table!(table, connection) }
      end

      # Each relation in a qualified parse, once. A RangeVar with no schema
      # left is a reference to a CTE.
      def tables(parse)
        ranges = nodes(parse.tree, PgQuery::RangeVar).reject { |range| range.schemaname.empty? }
        ranges.map { |range| TableName.new(schema: range.schemaname, name: range.relname) }.uniq
      end

      def plain_table!(table, connection)
        rows = connection.exec_params(RELKIND_SQL, [table.schema, table.name])
        raise Error.new("unknown_relation", "#{table} doesn't exist") if rows.ntuples.zero?

        relkind = rows.getvalue(0, 0)
        raise Error.new("not_a_table", "#{table} has relkind #{relkind}, not r") unless relkind == "r"
      end

      def volatility!(sql, settings, connection)
        VolatilityCheck.check(sql, settings, connection)
      rescue VolatilityCheck::Error => e
        raise Error.from(e), cause: nil
      end

      # Every node of type in the tree, in tree order.
      def nodes(node, type, found = [])
        case node
        when type then found << node
        when Google::Protobuf::RepeatedField then node.each { |child| nodes(child, type, found) }
        when PgQuery::Node then nodes(node.inner, type, found)
        when Google::Protobuf::MessageExts then node.class.descriptor.each { |field| nodes(field.get(node), type, found) }
        end
        found
      end
    end
  end
end
