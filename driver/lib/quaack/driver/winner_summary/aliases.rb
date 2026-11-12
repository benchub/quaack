# frozen_string_literal: true

module Quaack
  module Driver
    class WinnerSummary
      # Column qualifiers that name a table through an alias, written as the
      # table's name, so Repeats gives o.state and orders.state one shape
      # (20261110-21). A bare column stays bare: the driver has no schema to
      # say which table it belongs to.
      module Aliases
        module_function

        # Each alias of a table the tree always names one way, mapped to the
        # table's name, so o.state reads as orders.state (20261110-21). A
        # table named two ways, as in a self-join, keeps its aliases, so a.x
        # and b.x stay apart; one alias used for two tables is kept too.
        def of(tree)
          pairs = names(tree)
          one_way = once(pairs.map(&:last))
          single = once(pairs.map(&:first))
          pairs.select { |name, rel| name != rel && one_way.include?(rel) && single.include?(name) }.to_h
        end

        # Each distinct pair of the name a query reads a table by and the
        # table's own name.
        def names(tree)
          pairs = []
          tree.walk! do |_p, _f, node, _l|
            pairs << [table_name(node), node.relname] if node.is_a?(PgQuery::RangeVar)
          end
          pairs.uniq
        end

        def table_name(range_var) = range_var.alias&.aliasname.to_s.then { it.empty? ? range_var.relname : it }

        def once(list) = list.tally.select { _2 == 1 }.keys

        def resolve(name, map) = map.fetch(name, name)

        # Writes an alias qualifier as its table's name.
        def rename(column_ref, names)
          fields = column_ref.fields.to_a
          return unless fields.size == 2 && names.key?(fields.first.string&.sval)

          fields.first.string.sval = names[fields.first.string.sval]
        end
      end
    end
  end
end
