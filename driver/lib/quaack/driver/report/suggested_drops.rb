# frozen_string_literal: true

module Quaack
  module Driver
    module Report
      # Mixed into View: the existing indexes a ranked label's new indexes make truly
      # redundant, as the payload suggests dropping them (DESIGN.md's report).
      module SuggestedDrops
        # [{ "name", "size_bytes", "idx_scan" }]. An older payload, or a label that
        # isn't ranked, has none.
        def suggested_drops(label) = (measured(label) || {}).fetch("suggested_drops", [])

        # One suggested drop, as a list item: its name and size, and its scan count.
        def suggested_drop(drop)
          scans = drop["idx_scan"]
          counted = scans ? "production's statistics show #{Words.count(scans, "scan")}" : "its scan count isn't known"

          "#{Format.sql_span(drop["name"])} (#{Format.size(drop["size_bytes"])}), #{counted}"
        end

        # The new indexes' size less the dropped indexes', in bytes, or nil if any isn't
        # recorded.
        def net_added(label, sizes)
          dropped = suggested_drops(label).map { it["size_bytes"] }
          sizes.sum - dropped.sum if sizes.any? && (sizes + dropped).all?(Integer)
        end
      end
    end
  end
end
