# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of what a rewrite_test message says about why vacuity-guard
    # left atoms untested (DESIGN.md, "vacuity-guard"): s1_load_rule, the
    # rule S1 failed to load with (nil when it loaded), from LOAD_RULES, and
    # s1_rows, how many rows the original returned on S1 (nil when S1
    # didn't load), and s1_nonzero_rows, how many of those rows hold a value
    # that's neither NULL nor a numeric zero (nil when S1 didn't load), so an
    # aggregate's one row shows whether S1 matched anything. Never an error
    # message, a value, or SQL.
    #
    #   VacuityDiagnostic.valid?({ "s1_load_rule" => nil, "s1_rows" => 3 })  # => true
    module VacuityDiagnostic
      # The rules a fixture load can fail with, as ArenaRunner raises them in
      # its load and insert steps, plus other for any rule not named here,
      # and original_failed when S1 loaded but its rows made the original
      # query fail (a division by zero, say).
      LOAD_RULES = %w[fixture_load_failed insert_failed statement_timeout statement_canceled other original_failed]
                   .map(&:freeze).freeze

      # The most rows s1_rows may hold. S1 is a few dozen made-up rows (one
      # group of at most one row per table for the hit and each near miss,
      # see Scenarios::Plan), so the original's result is small, and the
      # arena's 10 s statement timeout (ArenaRunner::DEFAULT_STATEMENT_TIMEOUT_MS)
      # stops a join from running up a count: nothing in the code caps the
      # rows a query returns, so this is the same as the 2,000,000 elements
      # the enclave reads from any one input (CLI::Input::MAX_ELEMENTS), the
      # most it will hold of anything, and enclave/spec/vacuity_row_cap_spec.rb
      # keeps the two together.
      MAX_ROWS = 2_000_000

      module_function

      # Whether fields, as JSON reads them back (String keys), carry a
      # s1_load_rule that's nil or on LOAD_RULES and a s1_rows that's nil or
      # an Integer from zero up to MAX_ROWS, and the same for
      # s1_nonzero_rows. Other keys aren't checked.
      def valid?(fields)
        return false unless fields.is_a?(Hash)

        rule = fields["s1_load_rule"]
        rows = fields["s1_rows"]
        nonzero = fields["s1_nonzero_rows"]
        (rule.nil? || LOAD_RULES.include?(rule)) && (rows.nil? || count?(rows)) && (nonzero.nil? || count?(nonzero))
      end

      def count?(count) = count.is_a?(Integer) && count >= 0 && count <= MAX_ROWS

      private_class_method :count?
    end
  end
end
