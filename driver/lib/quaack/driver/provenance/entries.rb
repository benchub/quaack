# frozen_string_literal: true

module Quaack
  module Driver
    class Provenance
      # How a Provenance records its providers: each entry, and whether the
      # run marked it down or dropped it.
      module Entries
        # entries are each provider's name, provider type, and model. An
        # entry already recorded keeps its first record.
        def providers!(entries)
          list = (@record["providers"] ||= [])
          entries.each do |entry|
            clean = Shape.provider(entry.slice("name", "provider", "model"))
            list << clean if clean && list.none? { it["name"] == clean["name"] }
          end
          self
        end

        # downs maps each provider the run marked down or dropped to its rule.
        def down!(downs)
          downs.each do |name, rule|
            entry = Array(@record["providers"]).find { it["name"] == name }
            entry["down"] = rule if entry && RULE.match?(rule.to_s)
          end
          self
        end

        # names are the providers this run of quaack asked and didn't mark
        # down or drop: each loses the down an earlier run recorded, since a
        # resumed run tries it again (DESIGN.md, "Several LLM providers":
        # Provenance).
        def up!(names)
          Array(@record["providers"]).each { it.delete("down") if names.include?(it["name"]) }
          self
        end
      end
    end
  end
end
