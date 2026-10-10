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
        # that fails it (20261010-32). A bare boolean column isn't pooled.
        def call(atom)
          return one_column?(atom) if KINDS.include?(atom.kind)
          return atom.bare && one_column?(atom) if boolean_test?(atom)

          keyset?(atom)
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
