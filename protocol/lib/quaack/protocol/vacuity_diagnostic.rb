# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of what a rewrite_test message says about why vacuity-guard
    # left atoms untested (DESIGN.md, "vacuity-guard"): s1_load_rule, the
    # rule S1 failed to load with (nil when it loaded), from LOAD_RULES, and
    # s1_rows, how many rows the original returned on S1 (nil when S1
    # didn't load). Never an error message, a value, or SQL.
    #
    #   VacuityDiagnostic.valid?({ "s1_load_rule" => nil, "s1_rows" => 3 })  # => true
    module VacuityDiagnostic
      # The rules a fixture load can fail with, as ArenaRunner raises them in
      # its load and insert steps, plus other for any rule not named here.
      LOAD_RULES = %w[fixture_load_failed insert_failed statement_timeout statement_canceled other]
                   .map(&:freeze).freeze

      # As Burndown's: no real count comes near it.
      MAX_COUNT = 10**12

      module_function

      # Whether fields, as JSON reads them back (String keys), carry a
      # s1_load_rule that's nil or on LOAD_RULES and a s1_rows that's nil or
      # an Integer from zero up to below MAX_COUNT. Other keys aren't checked.
      def valid?(fields)
        return false unless fields.is_a?(Hash)

        rule = fields["s1_load_rule"]
        rows = fields["s1_rows"]
        (rule.nil? || LOAD_RULES.include?(rule)) && (rows.nil? || count?(rows))
      end

      def count?(count) = count.is_a?(Integer) && count >= 0 && count < MAX_COUNT

      private_class_method :count?
    end
  end
end
