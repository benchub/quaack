# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Mixed into View, after Providers: each LLM entry's calls, wait, and
      # tokens (DESIGN.md's report), from the driver's own counts, @llm's
      # "usage" (Burndown#llm_usage, by entry), never anything the enclave
      # sent. A count the provider didn't give is NOT_REPORTED, never 0.
      module Usage
        NOT_REPORTED = "not reported"

        # Each provider's wait and tokens (Burndown#llm_usage), by name.
        def provider_usage = @llm.fetch("usage", nil) || {}

        # The wait and tokens table's rows: one per entry of this run of
        # quaack, then the total, or none if no entry's wait was recorded.
        # Each row is its name, then calls, those failed or not used, the
        # wait, and the input, output, total, cached, and reasoning tokens,
        # each nil if not recorded and NOT_REPORTED if the provider didn't
        # say. The total adds up what was recorded and reported.
        def usage_rows
          return [] if provider_usage.empty?

          rows = call_columns.map { usage_row(it, calls_of(it) || 0, provider_usage[it]) }
          rows + [usage_total(rows)]
        end

        private

        def usage_row(name, calls, usage)
          return [name, calls, *[nil] * 7] unless usage

          [name, calls, calls - usage["used"], usage["seconds"], *tokens(usage)]
        end

        # input, output, their total, cached, and reasoning.
        def tokens(usage)
          return [NOT_REPORTED] * 5 if usage["reported"].zero?

          input, output = usage.values_at("input", "output")
          [input, output, input + output, *usage.values_at("cached", "reasoning").map { it || NOT_REPORTED }]
        end

        # The total row: each column's sum of what was recorded, the token
        # columns NOT_REPORTED where no entry reported any.
        def usage_total(rows)
          columns = rows.map { it.drop(1) }.transpose.map { it.grep(Numeric) }
          ["Total", *columns.each_with_index.map { |cells, i| i < 3 || cells.any? ? cells.sum : NOT_REPORTED }]
        end
      end
    end
  end
end
