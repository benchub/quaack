# frozen_string_literal: true

module Quaack
  module Enclave
    module RewriteRules
      class KeyInSelfJoin
        def name = "key_in_self_join"

        def description
          "An IN subquery that reads the outer table again by a unique, not-null key becomes that table's own " \
            "predicates, and an EXISTS on what's left of the subquery."
        end

        def rewrites(_parse, _catalog) = []
      end
    end
  end
end
