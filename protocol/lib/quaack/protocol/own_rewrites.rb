# frozen_string_literal: true

require_relative "rewrite_budget"

module Quaack
  module Protocol
    # A report's own_rewrites (task 20261021-2): each of the operator's own
    # rewrites (`--rewrites`), kept or not, as rewrite-check kept it. Each
    # entry has exactly KEYS: index (its 1-based position, an Integer),
    # sql (its text, with the original's $n placeholders, or nil when the
    # enclave's literal check held it back), outcome (accepted or
    # rejected), rule (a rejection's rule, a lowercase word), and rewrite
    # (a kept one's rewrite_<n>). Any of them may be nil. Egress and the
    # driver both check it with valid?; the enclave's ReportPayload is
    # where sql's literal check happens.
    module OwnRewrites
      KEYS = %w[index outcome rewrite rule sql].freeze
      OUTCOMES = [nil, "accepted", "rejected"].freeze
      NAME = /\Arewrite_[1-9][0-9]{0,8}\z/

      module_function

      # Whether list is nil or an Array of valid entries.
      def valid?(list) = list.nil? || (list.is_a?(Array) && list.all? { entry?(it) })

      def entry?(entry)
        entry.is_a?(Hash) && entry.keys.sort == KEYS && fields?(*entry.values_at(*%w[index sql outcome rule rewrite]))
      end

      def fields?(index, sql, outcome, rule, name)
        [NilClass, Integer].any? { index.is_a?(it) } && [NilClass, String].any? { sql.is_a?(it) } &&
          OUTCOMES.include?(outcome) && RewriteBudget.rule?(rule) && name?(name)
      end

      def name?(name) = name.nil? || (name.is_a?(String) && NAME.match?(name))
    end
  end
end
