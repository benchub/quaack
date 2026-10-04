# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # A group's tries, for Parts#add. First the group's rows, then lazily
      # its rows with its pooled columns' later fitting values, for
      # RowSet#add_any? to try when it collides: a second tag the filter
      # takes, when the hit holds the first on a unique name. Then, for
      # Parts to try last, the same for the group as each pooled atom's near
      # miss: a cross's other parent, when the filter pins the one unique
      # value the hit's parent holds. build gives a group's rows, or nil.
      class Retries
        def initialize(near_keys, &build)
          @near_keys = near_keys
          @build = build
        end

        # Nil when the group itself can't be built.
        def for(group)
          rows = @build.call(group) or return
          [shifts(group, rows)] + (group.near ? [] : @near_keys.map { shifts(group.with(near: it)) })
        end

        private

        def shifts(group, rows = @build.call(group))
          [rows].each + (1..SHIFTS).lazy.map { @build.call(group.with(shift: it)) }
        end
      end
    end
  end
end
