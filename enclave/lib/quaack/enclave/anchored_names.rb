# frozen_string_literal: true

require "pg_query"
require_relative "implicit_name"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # Clock anchoring (clock-anchor) changes the names Postgres makes up. It names an
    # output column that has no AS after the function it calls, so now()
    # is "now", and so is now()::date, but quaack.clock_anchor() is
    # "clock_anchor". A function in FROM with no alias names its table and
    # column the same way. A later reference to the old name, from an
    # outer query, ORDER BY, or GROUP BY, would then fail, or quietly find
    # a table's column of that name instead.
    #
    # So anchoring writes the old name in: an AS on the column, or an
    # alias on the function in FROM. An explicit name means the same as
    # the implicit one it spells out. Postgres names a FROM function's
    # single column after the alias, as it does after the function, since
    # clock_anchor() has no OUT parameter to name it.
    #
    # A slot is each place such a name comes from, an output column or a
    # function in FROM, numbered in the order NodeRewrite walks the tree.
    # Anchoring doesn't add or remove any, so the numbers hold from the
    # original to the anchored tree, and back.
    module AnchoredNames
      # One name anchoring added, and the slot it's on.
      Added = Data.define(:slot, :name)

      class Mismatch < StandardError; end

      module_function

      # Each slot's implicit name, or nil when it has an explicit one.
      def implicit_names(tree) = slots(tree).map { |slot| implicit(slot) }

      # Names each slot of the anchored tree whose implicit name changed
      # from before, in place, and returns what it added, by slot. Inner
      # slots go first, so a scalar subquery's column is named before the
      # outer column that takes its name from it.
      def keep(tree, before)
        slots(tree).each_with_index.reverse_each.filter_map do |slot, i|
          next unless before[i] && implicit(slot) != before[i]

          name(slot, before[i])
          Added.new(slot: i, name: before[i])
        end.reverse
      end

      # Takes each added name off again, in place. Raises Mismatch when a
      # slot doesn't have the name that was added there.
      def strip(tree, added)
        found = slots(tree)
        added.each do |name|
          slot = found[name.slot]
          raise Mismatch unless slot && explicit(slot) == name.name

          unname(slot)
        end
      end

      def slots(tree)
        found = []
        NodeRewrite.each(tree) do |node|
          found << (node.res_target || node.range_function) if node.res_target || node.range_function
          nil
        end
        found
      end

      def implicit(slot)
        case slot
        when PgQuery::ResTarget then ImplicitName.of(slot.val) if slot.name.empty?
        when PgQuery::RangeFunction then ImplicitName.of(slot.functions.first.list.items.first) unless slot.alias
        end
      end

      def explicit(slot)
        case slot
        when PgQuery::ResTarget then slot.name
        when PgQuery::RangeFunction then slot.alias&.colnames&.empty? ? slot.alias.aliasname : nil
        end
      end

      def name(slot, name)
        case slot
        when PgQuery::ResTarget then slot.name = name
        when PgQuery::RangeFunction then slot.alias = PgQuery::Alias.new(aliasname: name)
        end
      end

      def unname(slot)
        case slot
        when PgQuery::ResTarget then slot.name = ""
        when PgQuery::RangeFunction then slot.alias = nil
        end
      end
    end
  end
end
