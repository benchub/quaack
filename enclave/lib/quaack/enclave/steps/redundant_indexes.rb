# frozen_string_literal: true

require_relative "../index_candidate"
require_relative "../planner_statistics"

module Quaack
  module Enclave
    module Steps
      # The existing indexes a ranked label's new indexes make truly
      # redundant, for ReportPayload's labels (DESIGN.md's index-dedupe and
      # report). QUAACK only suggests the drop. It never makes one.
      #
      #   RedundantIndexes.new(store).drops("indexes" => ["quaack_ab12"])
      #   # => [{ "name" => "orders_created_at_idx", "size_bytes" => 40960, "idx_scan" => 12 }]
      #
      # The rule is strict, because the suggestion must never be a guess. An
      # existing index is redundant under a new one only if all hold:
      #
      # - same table, and both are btree;
      # - its key columns are a leading prefix of the new index's (or equal),
      #   in the same order, with the same direction, nulls ordering,
      #   expression, opclass, and collation (KeyColumn equality), so an
      #   expression index matches only an identical expression;
      # - the same predicate, or neither has one (as IndexCandidate
      #   normalizes it; implication between predicates doesn't count);
      # - every INCLUDE column is in the new index's key or INCLUDE list;
      # - it isn't unique, and backs no constraint (PRIMARY KEY, UNIQUE,
      #   EXCLUDE, or any other constraint's index), which the catalog read
      #   says as "constrained". An entry with no such fact never qualifies.
      #
      # idx_scan is production's pg_stat_user_indexes count, nil if unread.
      #
      # Trust boundary. Each entry is an index name (schema), a size, and a
      # scan count, the shape Protocol::SuggestedDrops.valid? checks in
      # egress and in the driver. The new indexes' DDL, with any predicate, is
      # read here and never goes out.
      class RedundantIndexes
        def initialize(store)
          @tables = store.read("statistics")["tables"].to_h do |table|
            [[table["schema"], table["name"]], table["indexes"]]
          end
          @built = store.read("index_build")["indexes"]
        end

        # Each ranked label (one of selection's top) with "suggested_drops",
        # and every other label as it is.
        def label(selection, labels)
          ranked = selection["top"].to_set { it["label"] }
          labels.map do |entry|
            ranked.include?(entry["label"]) ? entry.merge("suggested_drops" => drops(entry)) : entry
          end
        end

        # The drops for a label's built indexes (name => the index_build
        # entry's "ddl" as stored).
        def drops(label)
          found = label["indexes"].filter_map { @built.dig(it, "ddl") }.filter_map { candidate(it) }
          found.flat_map { redundant(it) }.uniq { [it[:table], it["name"]] }.map { it.except(:table) }
        end

        private

        def candidate(ddl) = IndexCandidate.from_ddl(ddl, sources: [:llm])

        def redundant(proposed)
          @tables.fetch([proposed.table.schema, proposed.table.name], []).filter_map do |entry|
            existing = existing(entry)
            next unless existing && strict?(existing, proposed)

            { :table => proposed.table, "name" => entry["name"], "size_bytes" => count(entry["size_bytes"]),
              "idx_scan" => count(entry["idx_scan"]) }
          end
        end

        # The entry's index, unless it's unique or backs a constraint, or QUAACK
        # can't read it; an entry with no "constrained" fact never qualifies.
        def existing(entry)
          IndexCandidate.from_indexdef(entry["definition"]) if entry["constrained"] == false && entry["definition"]
        end

        def strict?(existing, proposed)
          same_kind?(existing, proposed) && proposed.key.first(existing.key.size) == existing.key &&
            (existing.include - proposed.key.map(&:name) - proposed.include).empty?
        end

        def same_kind?(existing, proposed)
          [existing.table, existing.access_method, existing.predicate, existing.unique] ==
            [proposed.table, :btree, proposed.predicate, false] && proposed.access_method == :btree
        end

        def count(value) = (value if value.is_a?(Integer) && !value.negative?)
      end
    end
  end
end
