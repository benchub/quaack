# frozen_string_literal: true

require "pg_query"
require_relative "../deparse"
require_relative "../value_pools"

module Quaack
  module Enclave
    module Fuzz
      # The original with every cut removed, for Coverage: each LIMIT,
      # OFFSET, and FETCH FIRST (WITH TIES too), at the top and in every
      # subquery, CTE, and set operation's arm.
      #
      #   Uncut.parse("SELECT ... ORDER BY id LIMIT 20 OFFSET 40").query
      #   # => "SELECT ... ORDER BY id"
      #
      # Which rows a world's result keeps under a cut follows the cut's
      # literal, so whether an atom showed both ways on it would carry the
      # literal out of the enclave (task 20261012-4's fix round). Without
      # the cuts, the same for every literal, the WHERE and JOIN atoms are
      # evaluated as they are with them. Raises Deparse::Error when the
      # result doesn't deparse to a parse QUAACK trusts, or when a cut holds
      # anything but a constant or a parameter, since an atom in it (a
      # subquery's, say) would be gone (task 20261012-49); Coverage then
      # reports the worst case, never the cut query.
      module Uncut
        module_function

        # A PgQuery::ParseResult whose query is the uncut SQL, and whose
        # tree is the original's but for the cuts, so atoms' paths hold.
        def parse(sql)
          tree = Deparse.copy(PgQuery.parse(sql).tree)
          uncut!(tree)
          Deparse.faithful_parse(tree)
        end

        CUTS = %i[a_const param_ref].freeze

        def uncut!(node)
          if node.is_a?(PgQuery::SelectStmt)
            raise Deparse::Error if [node.limit_count, node.limit_offset].compact.any? { !CUTS.include?(it.node) }

            node.limit_count = nil
            node.limit_offset = nil
            node.limit_option = :LIMIT_OPTION_DEFAULT
          end
          ValuePools::Sides.children(node).each { uncut!(it) }
        end
      end
    end
  end
end
