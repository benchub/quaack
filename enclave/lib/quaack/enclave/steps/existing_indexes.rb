# frozen_string_literal: true

module Quaack
  module Enclave
    module Steps
      # The existing indexes' sizes, for ReportPayload and NegativeResult
      # (DESIGN.md's report): each existing index the report names goes out
      # with the size the planner statistics hold for it (pg_relation_size,
      # read in statistics).
      #
      #   sizes = ExistingIndexes.new(store)
      #   sizes.named(table, "orders_created_at_idx")
      #   # => { "name" => "orders_created_at_idx", "size_bytes" => 40960 }
      #
      # table is the TableName the index is on. size_bytes is nil when the
      # statistics hold no size for that index.
      #
      # Trust boundary. A name is schema. A size goes out only if it's an
      # Integer, so it's a count.
      class ExistingIndexes
        def initialize(store)
          @sizes = store.read("statistics")["tables"].to_h do |table|
            [[table["schema"], table["name"]], table["indexes"].to_h { [it["name"], it["size_bytes"]] }]
          end
        end

        def named(table, name)
          size = @sizes.dig([table.schema, table.name], name)
          { "name" => name, "size_bytes" => (size if size.is_a?(Integer)) }
        end
      end
    end
  end
end
