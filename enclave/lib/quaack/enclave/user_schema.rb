# frozen_string_literal: true

require "pg_query"
require_relative "relation_qualifier"

module Quaack
  module Enclave
    # DESIGN.md's qualify: "$user" in the search path resolves to the role
    # QUAACK connects as, not the role of the application that ran the plan.
    # A schema named for any other role is one the application's "$user"
    # may have meant. That matters only when such a schema has something the
    # query names without a schema, so the query is refused, as
    # ambiguous_user_schema, when one has:
    #
    # - a relation of the name of one the query names without a schema, and
    #   "$user" comes no later in the path than the schema it resolved to;
    # - a function of the name of one the query calls without a schema; or
    # - a type of the name of one the query names without a schema.
    #
    # Functions and types are refused wherever "$user" is, since overloads,
    # not just the path's order, choose among them. A schema the query names
    # nothing in, such as a monitoring tool's, doesn't matter. The operator's
    # own schema, if there is one, isn't refused.
    #
    #   UserSchema.check!(tree, resolved, settings, connection)
    #   # => nil, or raises Error "ambiguous_user_schema: the search path has ..."
    #
    # tree is the query's parse tree, and resolved what RelationQualifier's
    # qualify_tree returned for it: each unqualified relation name and the
    # TableName it resolved to. settings is the input plan's Settings hash,
    # or nil for the default path, and must read (RelationQualifier's
    # search_path checks that). Only the catalog is read. The message names
    # the schema and the relation, function, or type, which are
    # shape-class, and nothing else from the query.
    module UserSchema
      class Error < StandardError
        attr_reader :rule

        def initialize(schema, kind, name)
          @rule = "ambiguous_user_schema"
          super("#{rule}: the search path has \"$user\", and schema #{schema}, named for a role " \
                "other than the one QUAACK connects as, has a #{kind} named #{name}")
        end
      end

      # The first schema, by name, named for a role other than the
      # connecting one that has an object of a kind ($1) and name ($2), with
      # the first such kind and name, in the order given.
      SHADOW_SQL = <<~SQL
        SELECT n.nspname, wanted.kind, wanted.name
        FROM pg_catalog.pg_namespace n
        JOIN pg_catalog.pg_roles r ON r.rolname = n.nspname
        JOIN unnest($1::text[], $2::text[]) WITH ORDINALITY AS wanted(kind, name, position)
          ON (wanted.kind = 'relation' AND EXISTS (
                SELECT FROM pg_catalog.pg_class c WHERE c.relnamespace = n.oid AND c.relname = wanted.name))
          OR (wanted.kind = 'function' AND EXISTS (
                SELECT FROM pg_catalog.pg_proc p WHERE p.pronamespace = n.oid AND p.proname = wanted.name))
          OR (wanted.kind = 'type' AND EXISTS (
                SELECT FROM pg_catalog.pg_type t WHERE t.typnamespace = n.oid AND t.typname = wanted.name))
        WHERE n.nspname <> current_user
        ORDER BY n.nspname, wanted.position
        LIMIT 1
      SQL

      module_function

      def check!(tree, resolved, settings, connection)
        path = path(settings)
        user_at = path.index("$user") or return

        wanted = [*shadowable(resolved, path, user_at, connection).map { ["relation", it] }, *names(tree)].uniq
        return if wanted.empty?

        row = connection.exec_params(SHADOW_SQL, wanted.transpose.map { RelationQualifier.text_array(it) }).values[0]
        raise Error.new(*row), cause: nil if row
      end

      # The path's entries as Postgres searches them, "$user" as written.
      def path(settings)
        entries = RelationQualifier.path_entries(settings)
        entries.include?("pg_catalog") ? entries : ["pg_catalog", *entries]
      end

      # The unqualified relation names that resolved no earlier in the path
      # than "$user", so the application's "$user" schema would have come
      # first.
      def shadowable(resolved, path, user_at, connection)
        user = connection.exec("SELECT current_user").getvalue(0, 0)
        schemas = path.map { it == "$user" ? user : it }
        resolved.select { |_, table| user_at <= schemas.index(table.schema) }.keys
      end

      # Each function the tree calls, and each type it names, without a
      # schema, as [kind, name] pairs, in tree order.
      def names(node, found = [])
        case node
        when PgQuery::FuncCall then unqualified(found, "function", node.funcname)
        when PgQuery::TypeName then unqualified(found, "type", node.names)
        end
        children(node).each { names(it, found) }
        found
      end

      # Adds [kind, name] to found when the name list has no schema.
      def unqualified(found, kind, list) = (found << [kind, list[0].string.sval] if list.size == 1)

      def children(node)
        case node
        when Google::Protobuf::RepeatedField then node.to_a
        when PgQuery::Node then [node.inner]
        when Google::Protobuf::MessageExts then node.class.descriptor.map { it.get(node) }
        else []
        end
      end
    end
  end
end
