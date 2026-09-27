# frozen_string_literal: true

require "pg_query"
require_relative "relation_qualifier"

module Quaack
  module Enclave
    # README 3a: every function in a FROM item must be pg_catalog's, such
    # as generate_series or unnest. A user-defined one could read a view or
    # foreign table the relation check never sees.
    #
    #   FromFunctions.user_function?(tree, settings, connection) # => true or false
    #
    # It looks everywhere a FROM item goes: LATERAL, ROWS FROM, subqueries,
    # CTEs, and sublinks. A qualified name keeps its schema. An unqualified
    # one resolves to the first schema in the search path (as
    # RelationQualifier reads it) that the connecting role may use and that
    # has a function of that name. Overloads aren't told apart, so a
    # same-named function earlier in the path counts as that schema's. A
    # name no schema has isn't pg_catalog's. Only the catalog is read.
    module FromFunctions
      # The first schema of path $1, in order, that the connecting role may
      # use and that has a function named $2.
      SCHEMA_SQL = <<~SQL
        SELECT n.nspname
        FROM unnest($1::text[]) WITH ORDINALITY AS path(nspname, position)
        JOIN pg_catalog.pg_namespace n ON n.nspname = path.nspname
        WHERE pg_catalog.has_schema_privilege(n.oid, 'USAGE')
          AND EXISTS (SELECT 1 FROM pg_catalog.pg_proc p WHERE p.pronamespace = n.oid AND p.proname = $2)
        ORDER BY path.position
        LIMIT 1
      SQL

      module_function

      def user_function?(tree, settings, connection)
        path = nil
        names(tree).any? do |parts|
          next parts[-2] != "pg_catalog" if parts.size > 1

          path ||= RelationQualifier.text_array(RelationQualifier.search_path(settings, connection))
          connection.exec_params(SCHEMA_SQL, [path, parts.last]).values.dig(0, 0) != "pg_catalog"
        end
      end

      # The name parts of every function in a FROM item, in tree order.
      def names(node, found = [])
        case node
        when Google::Protobuf::RepeatedField then node.each { |child| names(child, found) }
        when PgQuery::Node then names(node.inner, found)
        when Google::Protobuf::MessageExts
          found.concat(calls(node)) if node.is_a?(PgQuery::RangeFunction)
          node.class.descriptor.each { |field| names(field.get(node), found) }
        end
        found
      end

      def calls(range)
        range.functions.map { |item| item.list.items.first.func_call.funcname.map { |part| part.string.sval } }
      end
    end
  end
end
