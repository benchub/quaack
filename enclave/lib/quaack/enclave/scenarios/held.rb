# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # The keys a group's own rows hold, by table and column list, each
      # built the first time a check asks, so finding a row's parent in
      # its own group doesn't scan the group per foreign key (task
      # 20261011-13). key computes a row's values of a column list.
      class Held
        def initialize(rows, &key)
          @by_table = rows.group_by(&:table)
          @key = key
          @index = {}
        end

        def held?(table, columns, wanted)
          @index.fetch([table, columns]) do
            @index[[table, columns]] = @by_table.fetch(table, []).to_h { [@key.call(it, columns), true] }
          end.key?(wanted)
        end
      end
    end
  end
end
