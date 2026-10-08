# frozen_string_literal: true

require "pg_query"
require_relative "../name_qualifier"

module Quaack
  module Enclave
    module RewriteCandidateCheck
      # The functions, types, collations, and operators a rewrite candidate
      # may use: the original's, as its qualified query writes them, and
      # pg_catalog's (20261008-32). It works on the parse alone, and never
      # reads the catalog, so its outcome can't depend on what a schema
      # holds.
      #
      # - A name the original writes the same way is kept as written.
      # - A name written in pg_catalog is kept.
      # - A bare name the original doesn't use is pinned to pg_catalog, so it
      #   resolves there or nowhere. A user schema on the search path, such
      #   as one named for a role, can never supply it, nor an overload of it.
      # - Any other name is refused as unknown_name, with one message that
      #   never names it.
      #
      # Operators written as keywords (IN, LIKE, BETWEEN, and the like) have
      # no qualified spelling, so they stay as written (see NameQualifier).
      module Names
        RULE = "unknown_name"
        DETAIL = "a rewrite may use only the original's functions, types, collations, and operators, " \
                 "and pg_catalog's"

        module_function

        # Pins parse's bare new names in place, or raises Error.
        def pin!(parse, original_sql)
          allowed = allowed(original_sql)
          names(parse.tree).each do |kind, list|
            next if allowed.include?(key(kind, list))

            pin_one!(list)
          end
        end

        # The original's names, as keys.
        def allowed(original_sql)
          original_sql ? names(PgQuery.parse(original_sql).tree).to_set { key(*it) } : Set.new
        end

        def pin_one!(list)
          strings = list.map { it.string.sval }
          return if strings.size == 2 && strings.first == "pg_catalog"
          raise Error.new(RULE, DETAIL) unless strings.size == 1

          list.unshift(PgQuery::Node.new(string: PgQuery::String.new(sval: "pg_catalog")))
        end

        def key(kind, list) = [kind, list.map { it.string.sval }]

        # Each name in the tree, as [kind, its name list].
        def names(tree)
          nodes = []
          NameQualifier.collect(tree, nodes)
          nodes.filter_map do |node|
            field, _pick, kind = NameQualifier::NAMES[node.class]
            next if field.nil?
            next if node.is_a?(PgQuery::A_Expr) && !NameQualifier::OPERATOR_KINDS.include?(node.kind)

            list = node.public_send(field)
            [kind, list] unless list.empty?
          end
        end
      end
    end
  end
end
