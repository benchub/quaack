# frozen_string_literal: true

module Quaack
  module Protocol
    # The shape of the report's hidden_statistics (DESIGN.md's statistics and
    # report): the statistics the production role couldn't see, which the
    # run went on without. indexes is the expression indexes' names, which
    # are schema and which the report names elsewhere too. extended_statistics
    # is only a count of the CREATE STATISTICS objects, since the report
    # names no extended statistics object.
    module HiddenStatistics
      KEYS = %w[extended_statistics indexes].map(&:freeze).freeze

      # As Burndown's: no real count comes near it.
      MAX_COUNT = 10**12

      module_function

      # Whether field, as JSON reads it back, is exactly KEYS, as Strings:
      # indexes an Array of Strings, and extended_statistics an Integer from
      # zero up to below MAX_COUNT. The one check on what it may carry, for
      # the enclave's egress function and the driver both.
      def valid?(field)
        field.is_a?(Hash) && field.keys.all?(String) && field.keys.sort == KEYS &&
          field["indexes"].is_a?(Array) && field["indexes"].all?(String) &&
          field["extended_statistics"].is_a?(Integer) && field["extended_statistics"].between?(0, MAX_COUNT - 1)
      end
    end
  end
end
