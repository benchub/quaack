# frozen_string_literal: true

require "pg_query"
require_relative "relation_qualifier"
require_relative "unqualified_names"

module Quaack
  module Enclave
    # DESIGN.md's qualify: "$user" in the search path resolves to the role
    # QUAACK connects as, not the role of the application that ran the plan.
    # For the application it may have named any schema named for a role,
    # the operator's own included, or none. That matters only when such a
    # schema has something the query names without a schema, and could
    # change what the name resolves to, so the query is refused, as
    # ambiguous_user_schema, when a role's schema, put where "$user" is in
    # the path, could change:
    #
    # - which relation, type, or collation a name the query uses without a
    #   schema resolves to. Postgres takes the first of the name in the
    #   path, so the schema matters only when no schema before "$user" has
    #   the name (one the connecting role has no USAGE on doesn't count,
    #   since Postgres skips it), and the path doesn't list it as the first
    #   schema after "$user" that has the name (here every schema counts,
    #   so an unusable one refuses rather than passes); or
    # - which function or operator a name the query uses without a schema
    #   resolves to. Postgres chooses among every one of the name in the
    #   path, by argument types and then path order, so the schema matters
    #   unless the path lists it before "$user" (where "$user" adds nothing)
    #   or lists it after "$user" with no schema between that has the name.
    #
    # UnqualifiedNames says which operators count. A schema the query names nothing in, such as a monitoring tool's,
    # doesn't matter.
    #
    #   UserSchema.check!(tree, resolved, settings, connection)
    #   # => nil, or raises Error "ambiguous_user_schema: the search path has ..."
    #
    # tree is the query's parse tree, and resolved what RelationQualifier's
    # qualify_tree returned for it: each unqualified relation name and the
    # TableName it resolved to. settings is the input plan's Settings hash,
    # or nil for the default path, and must read (RelationQualifier's
    # search_path checks that). Only the catalog is read. The message names
    # the schema and the relation, type, collation, function, or operator,
    # which are shape-class, and nothing else from the query.
    module UserSchema
      class Error < StandardError
        attr_reader :rule

        def initialize(schema, kind, name, own)
          @rule = "ambiguous_user_schema"
          whose = own == "t" ? "the role QUAACK connects as" : "a role other than the one QUAACK connects as"
          super("#{rule}: the search path has \"$user\", and schema #{schema}, named for #{whose}, " \
                "has #{kind == "operator" ? "an" : "a"} #{kind} named #{name}, " \
                "so #{name} could resolve to a schema the application never saw")
        end
      end

      # Kinds Postgres resolves to the first of the name in the path.
      FIRST_FOUND = %w[relation type collation].freeze

      # The first schema, by name, named for a role, that could change what
      # a wanted kind ($2) and name ($3) resolves to were it at "$user", at
      # position $4 of the path $1, with the first such kind and name, in
      # the order given, and whether it's the connecting role's. $5 lists
      # the FIRST_FOUND kinds.
      SHADOW_SQL = <<~SQL
        WITH path AS (
          SELECT entry, min(position) AS position
          FROM unnest($1::text[]) WITH ORDINALITY AS p(entry, position)
          WHERE entry <> '$user'
          GROUP BY entry
        ),
        wanted AS (
          SELECT kind, name, position FROM unnest($2::text[], $3::text[]) WITH ORDINALITY AS w(kind, name, position)
        ),
        holders AS (
          SELECT n.nspname, wanted.kind, wanted.name, wanted.position,
            pg_catalog.has_schema_privilege(n.oid, 'USAGE') AS usable
          FROM pg_catalog.pg_namespace n
          JOIN wanted ON CASE wanted.kind
            WHEN 'relation' THEN EXISTS (
              SELECT FROM pg_catalog.pg_class c WHERE c.relnamespace = n.oid AND c.relname = wanted.name)
            WHEN 'type' THEN EXISTS (
              SELECT FROM pg_catalog.pg_type t WHERE t.typnamespace = n.oid AND t.typname = wanted.name)
            WHEN 'collation' THEN EXISTS (
              SELECT FROM pg_catalog.pg_collation l WHERE l.collnamespace = n.oid AND l.collname = wanted.name)
            WHEN 'function' THEN EXISTS (
              SELECT FROM pg_catalog.pg_proc f WHERE f.pronamespace = n.oid AND f.proname = wanted.name)
            WHEN 'operator' THEN EXISTS (
              SELECT FROM pg_catalog.pg_operator o WHERE o.oprnamespace = n.oid AND o.oprname = wanted.name)
          END
        ),
        listed AS (
          SELECT holders.*, path.position AS listed_at FROM holders LEFT JOIN path ON path.entry = holders.nspname
        )
        SELECT shadow.nspname, shadow.kind, shadow.name, shadow.nspname = current_user
        FROM listed shadow
        JOIN pg_catalog.pg_roles r ON r.rolname = shadow.nspname
        WHERE (shadow.listed_at IS NULL OR EXISTS (
            SELECT FROM listed nearer
            WHERE (nearer.kind, nearer.name) = (shadow.kind, shadow.name)
              AND nearer.listed_at > $4::int AND nearer.listed_at < shadow.listed_at))
          AND NOT (shadow.kind = ANY ($5::text[]) AND EXISTS (
            SELECT FROM listed found
            WHERE (found.kind, found.name) = (shadow.kind, shadow.name) AND found.listed_at < $4::int
              AND found.usable))
        ORDER BY shadow.nspname, shadow.position
        LIMIT 1
      SQL

      module_function

      def check!(tree, resolved, settings, connection)
        path = path(settings)
        user_at = path.index("$user") or return

        wanted = [*resolved.keys.map { ["relation", it] }, *UnqualifiedNames.of(tree)].uniq
        return if wanted.empty?

        row = connection.exec_params(SHADOW_SQL, params(path, wanted, user_at)).values[0]
        raise Error.new(*row), cause: nil if row
      end

      def params(path, wanted, user_at)
        kinds, names = wanted.transpose
        [path, kinds, names, user_at + 1, FIRST_FOUND].map { it.is_a?(Array) ? RelationQualifier.text_array(it) : it }
      end

      # The path's entries as Postgres searches them, "$user" as written.
      def path(settings)
        entries = RelationQualifier.path_entries(settings)
        entries.include?("pg_catalog") ? entries : ["pg_catalog", *entries]
      end
    end
  end
end
