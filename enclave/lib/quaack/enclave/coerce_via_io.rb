# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The casts Postgres does through text, by a type's output and input
    # functions (CoerceViaIO), in a view ResolvedCalls made, which no call
    # names (20261118-223225-2).
    #
    #   CoerceViaIo.functions("pg_temp.v", connection)
    #   # => [["pg_catalog", "timestamptz_out", "pg_catalog", "timestamptz_out", "stable", true]]
    #
    # Each row is a ResolvedCalls::Function's fields, for each such output
    # or input function that isn't IMMUTABLE.
    module CoerceViaIo
      # The view's stored tree, which pairs reads.
      TREE_SQL = <<~SQL
        SELECT r.ev_action::pg_catalog.text FROM pg_catalog.pg_rewrite r
        WHERE r.ev_class OPERATOR(pg_catalog.=) $1::pg_catalog.regclass
      SQL

      # The output functions of $1's types and the input functions of
      # $2's that aren't IMMUTABLE (20261118-223225-2).
      COERCIONS_SQL = <<~SQL
        SELECT DISTINCT n.nspname, p.proname, pg_catalog.quote_ident(n.nspname), pg_catalog.quote_ident(p.proname),
               CASE WHEN p.provolatile OPERATOR(pg_catalog.=) 's' THEN 'stable' ELSE 'volatile' END, true
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_proc p
          ON (t.oid OPERATOR(pg_catalog.=) ANY ($1::pg_catalog.oid[]) AND p.oid OPERATOR(pg_catalog.=) t.typoutput)
          OR (t.oid OPERATOR(pg_catalog.=) ANY ($2::pg_catalog.oid[]) AND p.oid OPERATOR(pg_catalog.=) t.typinput)
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
        WHERE p.provolatile OPERATOR(pg_catalog.<>) 'i'
        ORDER BY 1, 2
      SQL

      COERCE_VIA_IO = "{COERCEVIAIO :arg "
      BRACES = { "{" => 1, "}" => -1 }.freeze

      module_function

      def functions(view, connection)
        tree = connection.exec_params(TREE_SQL, [view]).getvalue(0, 0)
        pairs = pairs(tree)
        return [] if pairs.empty?

        connection.exec_params(COERCIONS_SQL, pairs.transpose.map { "{#{it.join(",")}}" }).values
      end

      # Each CoerceViaIO's [argument type, result type] oids. The argument
      # type is the first field ending in "type" at its node's top level.
      # The shell has no strings, so every brace in the tree is a node's.
      def pairs(tree)
        starts = tree.enum_for(:scan, COERCE_VIA_IO).map { Regexp.last_match.end(0) }
        starts.filter_map { pair(tree, it) }
      end

      def pair(tree, arg_start)
        arg_end = node_end(tree, arg_start)
        arg_type = top_level(tree[(arg_start + 1)...arg_end])[/:\w*type (\d+)/, 1]
        result_type = tree[(arg_end + 1)..][/\A\s*:resulttype (\d+)/, 1]
        [arg_type, result_type] if arg_type && result_type
      end

      def node_end(tree, open)
        depth = 0
        (open...tree.length).find { |i| (depth += BRACES.fetch(tree[i], 0)).zero? } || tree.length
      end

      def top_level(node)
        stripped = node.gsub(/\{[^{}]*\}/, "")
        stripped == node ? node : top_level(stripped)
      end

      # Whether a value has a cast, or a call that may be a function-style
      # one, which Postgres may do through text.
      def casts?(message)
        return true if message.is_a?(PgQuery::TypeCast) || message.is_a?(PgQuery::FuncCall)

        message.class.descriptor.any? do |field|
          value = field.get(message)
          values = value.is_a?(Google::Protobuf::RepeatedField) ? value.to_a : [value]
          values.grep(Google::Protobuf::MessageExts).any? { casts?(it) }
        end
      end
    end
  end
end
