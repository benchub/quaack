# frozen_string_literal: true

module Quaack
  module Enclave
    module ValuePools
      # Which atoms get a pool (see ValuePools.pooled?).
      module Pooled
        KINDS = %i[equality range like in null_test].freeze

        # The row comparison operators whose leading column can decide them.
        ROW_RANGE = %w[< <= > >=].freeze

        module_function

        # An equality, range, LIKE, IN, or IS NULL test on one column of a
        # plain table is pooled. A keyset row comparison with a range
        # operator is pooled through its leading column, when every element
        # of its column row is a plain column of a table. A boolean test (IS
        # TRUE, IS NOT FALSE, ...) on a plain column of a table is pooled
        # too: the probe sorts t, f, and NULL, so the near miss gets a value
        # that fails it (20261010-32). A bare boolean column is pooled only
        # inside an aggregate's FILTER, where its default (false) would
        # leave every group out of the aggregate, so loosening any other
        # atom could change nothing (20261010-36). Elsewhere it isn't: a
        # NOT arm of an OR (muted IS NULL OR NOT muted) relies on the
        # default, which Branches masks around.
        def call(atom)
          return one_column?(atom) if KINDS.include?(atom.kind)
          return atom.bare && one_column?(atom) if boolean_test?(atom)
          return one_column?(atom) if filter_column?(atom)

          keyset?(atom)
        end

        # A bare column inside an aggregate's FILTER.
        def filter_column?(atom)
          atom.kind == :other && atom.operator.nil? && atom.bare && atom.path.include?("agg_filter")
        end

        def keyset?(atom)
          atom.kind == :row_comparison && ROW_RANGE.include?(atom.operator) && atom.bare && atom.columns.all?(&:table)
        end

        def one_column?(atom) = atom.columns.size == 1 && !atom.columns[0].table.nil?

        # IS TRUE and its kin.
        def boolean_test?(atom) = atom.kind == :other && atom.operator.to_s.start_with?("IS ")
      end
    end
  end
end
