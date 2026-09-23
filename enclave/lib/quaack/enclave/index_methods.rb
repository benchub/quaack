# frozen_string_literal: true

module Quaack
  module Enclave
    # What each built-in index method supports, so IndexCandidate can refuse
    # a definition Postgres would reject. It's private to the enclave
    # namespace. The facts come from pg_indexam_has_property on Postgres 18.
    #
    # Only btree can order its entries or be unique, so any other method,
    # even one this doesn't know about, is refused for those. Postgres
    # refuses DESC or NULLS FIRST/LAST on any other method, even where
    # HypoPG doesn't. It's the other way around for INCLUDE and several key
    # columns: only the built-in methods named below are known to lack them,
    # so a method this doesn't know about is allowed both.
    module IndexMethods
      module_function

      NO_INCLUDE = %i[brin gin hash].freeze
      ONE_KEY_COLUMN = %i[hash spgist].freeze

      def check(method, key:, include:, unique:)
        raise ArgumentError, "unique must be true or false, got #{unique.inspect}" unless [true, false].include?(unique)

        problem = (btree_only_problem(method, key, unique) unless method == :btree) ||
                  missing_feature_problem(method, key, include)
        raise ArgumentError, problem if problem
      end

      def btree_only_problem(method, key, unique)
        if !key.all?(&:default_order?)
          "only btree takes a non-default direction or nulls ordering, not #{method}"
        elsif unique
          "a unique index must use btree, not #{method}"
        end
      end

      def missing_feature_problem(method, key, include)
        if include.any? && NO_INCLUDE.include?(method)
          "#{method} doesn't support INCLUDE columns"
        elsif key.size > 1 && ONE_KEY_COLUMN.include?(method)
          "#{method} doesn't support more than one key column"
        end
      end
    end

    private_constant :IndexMethods
  end
end
