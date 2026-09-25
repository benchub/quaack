# frozen_string_literal: true

require "pg_query"
require_relative "function_calls"
require_relative "relation_qualifier"
require_relative "supported_sql"
require_relative "volatility_check"

module Quaack
  module Enclave
    # The value checks of InsertCheck, which says what they are: rules
    # not_plain_value, not_immutable, bad_search_path, and
    # volatile_function, in that order.
    #
    #   InsertValues.check(rows, settings, connection)
    #   # => nil, or raises Error "not_immutable: function pg_catalog.now is stable, not immutable"
    #
    # rows is the VALUES list, each row an Array of PgQuery::Nodes. Errors
    # follow the "rule: detail" form, name only node types and function
    # names, and have no cause.
    module InsertValues
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      # The functions a call could reach that aren't IMMUTABLE, by the 3d
      # check's rule for which ones a call could reach.
      MUTABLE_SQL = <<~SQL
        SELECT pg_catalog.quote_ident(n.nspname), pg_catalog.quote_ident(p.proname),
               CASE p.provolatile WHEN 's' THEN 'stable' ELSE 'volatile' END
        FROM pg_catalog.pg_proc p
        JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = ANY ($1::text[]) AND p.proname = $2 AND p.provolatile <> 'i'
          AND $3::int >= p.pronargs - p.pronargdefaults
          AND ($3::int <= p.pronargs OR p.provariadic <> 0)
        ORDER BY pg_catalog.array_position($1::text[], n.nspname::text), p.oid
        LIMIT 1
      SQL

      # The FuncCall fields that make it an aggregate or window call, or
      # otherwise more than a plain call.
      AGGREGATE_SYNTAX = %i[agg_order agg_filter over agg_within_group agg_star agg_distinct func_variadic].freeze

      module_function

      def check(rows, settings, connection)
        rows.each { |row| row.each { |value| plain!(value) unless value.node == :set_to_default } }
        probe = probe(rows)
        immutable!(probe, settings, connection)
        volatility!(probe, settings, connection)
        nil
      end

      def plain!(node)
        inner = node.inner
        case inner
        when PgQuery::A_Const then nil
        when PgQuery::TypeCast then plain!(inner.arg)
        when PgQuery::A_ArrayExpr then inner.elements.each { |element| plain!(element) }
        when PgQuery::FuncCall then function!(inner)
        else not_plain!(inner)
        end
      end

      def not_plain!(inner)
        raise Error.new("not_plain_value", "a value uses #{inner.class.name.split("::").last}")
      end

      def function!(func)
        if AGGREGATE_SYNTAX.any? { |field| used?(func.public_send(field)) }
          raise Error.new("not_plain_value", "a value uses an aggregate or window call")
        end

        func.args.each { |arg| plain!(arg) }
      end

      def used?(value) = value.respond_to?(:empty?) ? !value.empty? : value

      # The values, DEFAULTs left out, as a SELECT's target list: the shape
      # FunctionCalls and VolatilityCheck read. It's built as a tree, so the
      # parse has no text of its own.
      def probe(rows)
        targets = rows.flatten.reject { |value| value.node == :set_to_default }
                      .map { |value| PgQuery::Node.from(PgQuery::ResTarget.new(val: value)) }
        select = PgQuery::SelectStmt.new(target_list: targets, limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        tree = PgQuery::ParseResult.new(stmts: [PgQuery::RawStmt.new(stmt: PgQuery::Node.from(select))])
        PgQuery::ParserResult.new("", tree)
      end

      def immutable!(probe, settings, connection)
        path = nil
        FunctionCalls.of(probe.tree).uniq.select { |call| call.kind == :function }.each do |call|
          schemas = call.schema ? [call.schema] : (path ||= search_path(settings, connection))
          mutable!(call, schemas, connection)
        end
      end

      def mutable!(call, schemas, connection)
        params = [RelationQualifier.text_array(schemas), call.name, call.arity.to_s]
        rows = connection.exec_params(MUTABLE_SQL, params)
        return if rows.ntuples.zero?

        schema, name, volatility = rows.values.first
        raise Error.new("not_immutable", "function #{schema}.#{name} is #{volatility}, not immutable")
      end

      def search_path(settings, connection)
        RelationQualifier.search_path(settings, connection)
      rescue RelationQualifier::Error => e
        raise Error.new("bad_search_path", e.message), cause: nil
      end

      def volatility!(probe, settings, connection)
        VolatilityCheck.check_parse(probe, settings, connection)
      rescue SupportedSql::Error, VolatilityCheck::Error => e
        raise Error.new(e.rule, e.message.delete_prefix("#{e.rule}: ")), cause: nil
      end
    end
  end
end
