# frozen_string_literal: true

require_relative "relation_qualifier"

module Quaack
  module Enclave
    # DESIGN.md's qualify: "$user" in the search path resolves to the role
    # QUAACK connects as, not the role of the application that ran the plan.
    # A schema named for any other role is one the application's "$user"
    # may have meant, so a path with "$user" is refused, as
    # ambiguous_user_schema, while such a schema exists. The operator's own
    # schema, if there is one, isn't refused. Functions resolve through the
    # path too, so it's refused whether or not the query names a relation
    # without its schema.
    #
    #   UserSchema.check!(settings, connection)
    #   # => nil, or raises Error "ambiguous_user_schema: the search path has ..."
    #
    # settings is the input plan's Settings hash, or nil for the default
    # path, and must read (RelationQualifier.search_path checks that). Only
    # the catalog is read. The message names the schema, which is
    # shape-class, and nothing from the query.
    module UserSchema
      class Error < StandardError
        attr_reader :rule

        def initialize(schema)
          @rule = "ambiguous_user_schema"
          super("#{rule}: the search path has \"$user\", and schema #{schema} is named for a role " \
                "other than the one QUAACK connects as")
        end
      end

      # The first schema, by name, named for a role other than the
      # connecting one.
      OTHER_USER_SCHEMA_SQL = <<~SQL
        SELECT n.nspname
        FROM pg_catalog.pg_namespace n
        JOIN pg_catalog.pg_roles r ON r.rolname = n.nspname
        WHERE n.nspname <> current_user
        ORDER BY n.nspname
        LIMIT 1
      SQL

      module_function

      def check!(settings, connection)
        return unless RelationQualifier.path_entries(settings).include?("$user")

        schema = connection.exec(OTHER_USER_SCHEMA_SQL).values.dig(0, 0)
        raise Error.new(schema), cause: nil if schema
      end
    end
  end
end
