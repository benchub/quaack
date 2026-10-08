# frozen_string_literal: true

require "pg_query"
require_relative "name_qualifier/catalog"
require_relative "name_qualifier/error"
require_relative "name_qualifier/reg_literal"

module Quaack
  module Enclave
    # DESIGN.md's qualify, for every name the query uses other than a
    # relation's: functions, operators, types, collations, and the names in
    # regclass and regtype literals. It names a schema wherever doing so
    # can't change what the name resolves to.
    #
    #   NameQualifier.qualify!(tree, path, connection)
    #
    # tree is a parse tree, changed in place. path is the search path as
    # RelationQualifier.search_path gives it, and connection reads only the
    # catalog. Only schemas on the path that the connecting role has USAGE
    # on count, as Postgres skips the others.
    #
    # - A type or collation is the first of its name on the path, so it gets
    #   that schema, unless that's pg_catalog. A pg_catalog one stays bare:
    #   later steps run with the plan's search path (RunServer.connect), so
    #   it resolves the same way there.
    # - A function, or an operator written as one (a + b, a = ANY (...),
    #   ORDER BY a USING <), gets a schema only when exactly one schema on
    #   the path has one of that name, and it isn't pg_catalog. Postgres
    #   picks among every one of the name on the path by argument types, so
    #   with more than one schema, such as an extension's = beside
    #   pg_catalog's, which wins isn't known without the query's types. Those
    #   stay bare, and so do the operators Postgres supplies or that are
    #   written as keywords (IN, BETWEEN, LIKE, and the like). They resolve
    #   through the plan's search path in later steps.
    # - A regclass or regtype literal: see RegLiteral, which refuses some.
    #
    # A name that resolves nowhere is left bare, but in a regclass literal.
    # A refusal raises Error, whose message names only the rule and the
    # literal's type, never the literal.
    module NameQualifier
      # The A_Expr kinds whose name is an operator's, written as one. The
      # others, written as keywords (IN, LIKE, BETWEEN, IS DISTINCT FROM,
      # NULLIF, and the like), have no qualified spelling. Today the filter
      # changes nothing, so no test can fail without it (task 20261007-30):
      # pg_catalog has every operator those keywords name, so the :only pick
      # always finds more than one schema, or only pg_catalog, and leaves
      # them bare. It's kept as a defense, so that a change to how operators
      # are picked can never put a schema on a keyword's operator.
      OPERATOR_KINDS = %i[AEXPR_OP AEXPR_OP_ANY AEXPR_OP_ALL].freeze

      # Each node type's name list, and how its schema is picked: :first,
      # the first schema with the name, or :only, the only one.
      NAMES = {
        PgQuery::FuncCall => %i[funcname only function],
        PgQuery::TypeName => %i[names first type],
        PgQuery::CollateClause => %i[collname first collation],
        PgQuery::A_Expr => %i[name only operator],
        PgQuery::SubLink => %i[oper_name only operator],
        PgQuery::SortBy => %i[use_op only operator]
      }.freeze

      module_function

      def qualify!(tree, path, connection)
        catalog = Catalog.new(path, connection)
        nodes = []
        collect(tree, nodes)
        # Literals first: a cast to regclass names pg_catalog's type.
        nodes.grep(PgQuery::TypeCast).each { RegLiteral.qualify!(it, catalog) }
        nodes.each { name!(it, catalog) }
      end

      def collect(node, found)
        case node
        when Google::Protobuf::RepeatedField then node.each { collect(it, found) }
        when PgQuery::Node then collect(node.inner, found)
        when Google::Protobuf::MessageExts
          found << node
          node.class.descriptor.each { |field| collect(field.get(node), found) }
        end
      end

      def name!(node, catalog)
        field, pick, kind = NAMES[node.class]
        return if field.nil? || (node.is_a?(PgQuery::A_Expr) && !OPERATOR_KINDS.include?(node.kind))

        names = node.public_send(field)
        names.replace(catalog.qualified(kind, names, pick)) if names.size == 1
      end
    end
  end
end
