# frozen_string_literal: true

require_relative "../clock_anchoring"

module Quaack
  module Enclave
    module Steps
      # `quaacks anchor --run <run ID>` (DESIGN.md's clock-anchor): anchors the clock in the
      # run's redacted query (see ClockAnchoring).
      #
      # It runs after `quaacks redact`. It reads redacted_query, the
      # search_path in plan's Settings, placeholder_map for the clock-reading
      # literals, and statistics for the column types they're compared with
      # (see ClockLiterals). It doesn't touch production. It
      # writes two entries: anchored_query, the SQL the run server runs
      # (PlanGate.check and index-test take it); and clock_replacements,
      # {"replacements" => [{"original", "anchored"}], "added_names" =>
      # [{"slot", "name"}]}, which ClockAnchoring.restore takes to put the
      # original functions back for the report. Both are shape: the
      # literals are already placeholders, and the replacements are
      # function names, or the placeholder a clock literal was. The words
      # themselves are never written. Everything is
      # computed before the first write, so a refusal stores nothing.
      #
      # It sends nothing itself. Its only line is DONE.
      module Anchor
        module_function

        def call(store:, **)
          result = anchored(store)
          replacements = { "replacements" => result.replacements.map { it.to_h.transform_keys(&:to_s) },
                           "added_names" => result.added_names.map { it.to_h.transform_keys(&:to_s) } }
          store.write("anchored_query", result.sql)
          store.write("clock_replacements", replacements)
          []
        end

        def anchored(store)
          ClockAnchoring.anchor(store.read("redacted_query"), store.read("plan")[0]["Settings"],
                                placeholder_map: store.read("placeholder_map"), statistics: store.read("statistics"))
        end
      end
    end
  end
end
