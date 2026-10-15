# frozen_string_literal: true

require "quaack/protocol/fuzz_result"
require_relative "../generator"
require_relative "../generator/uniques"

module Quaack
  module Enclave
    module Fuzz
      module Enumerate
        # Every small world over each table's row kinds (Kinds), in order of
        # weight: a world's rows plus each row's kind cost (Kinds::Table#cost),
        # so worlds with few rows and few changes from the base row come
        # first, where a kill is most likely and smallest.
        #
        #   worlds = Worlds.new(catalog, plan, domains, kinds)
        #   (0..worlds.max_weight).each { |w| worlds.each(w) { |rows| ... } }
        #   worlds.bound(w)   # => 2: every world of up to 2 rows weighs w or less
        #
        # A world of weight w is each split of n rows (0 to w) over the
        # tables, at most MAX_PER_TABLE each, that can load (a table whose
        # NOT NULL foreign key points to an empty table can't have rows),
        # each multiset of kinds per table whose costs add up to w - n, and
        # each way to point each row's foreign keys at a row of the parent
        # table in the world, or NULL where the key allows it. A row's other
        # planned columns hold one fixed value each: NULL in a cut key; the
        # nth of its key class's values and shared keys in a key class's
        # single-column unique key (:pk), or the column's next unique value
        # (Domains#unique) when the table has more rows than those, unless
        # the queries compare it with a constant, when its kind gives it
        # one, and, when an earlier row of the table has it, the first next
        # unique value no earlier row has; the next unique value in a unique
        # one; and an ordinary one in a required one. The next unique value
        # cycles through a CHECK's constants when a CHECK pins the column,
        # so it can repeat one already in the world. A row that repeats a
        # unique key's values already in the world gets the next unique
        # value in one of the key's columns instead, as the fuzz search's do
        # (Generator::Uniques), and is left out when none can take one or
        # the value it takes repeats one too.
        class Worlds # rubocop:disable Metrics/ClassLength -- the enumeration and its bound, which must agree
          MAX_PER_TABLE = 4
          MAX_COST = 2

          def initialize(catalog, plan, domains, kinds)
            @catalog = catalog
            @plan = plan
            @domains = domains
            @tables = plan.order
            @kinds = @tables.to_h { [it, kinds.for(it)] }
            @keys = @tables.to_h { |t| [t, plan.entries_for(t).select { it.kind == :fk }.map(&:fk).uniq] }
          end

          def max_rows = MAX_PER_TABLE * @tables.size

          def max_weight = (1 + MAX_COST) * max_rows

          # Each world of exactly weight, as fresh Generator::Rows, parents first.
          def each(weight, &)
            (0..[weight, max_rows].min).each do |rows|
              splits(rows).each { |split| choose(split, 0, weight - rows, {}) { wire(it, &) } }
            end
          end

          # The most rows r, up to Protocol::FuzzResult::MAX_BOUND, such that
          # every world of r rows or fewer weighs weight or less, and so has
          # been given once each weight up to weight has: r rows and each
          # table's rows at its costliest kind. 0 when none has.
          def bound(weight)
            (0..Protocol::FuzzResult::MAX_BOUND).take_while { heaviest(it) <= weight }.last || 0
          end

          private

          def heaviest(rows)
            splits(rows).map { |split| rows + @tables.each_index.sum { split[it] * costliest(@tables[it]) } }
                        .max || rows
          end

          def costliest(table)
            kind = @kinds.fetch(table)
            kind.cost(kind.kinds.size - 1)
          end

          # Each viable split of rows over the tables, fewest per table first.
          def splits(rows)
            found = []
            counts(rows, 0, []) { found << it if viable?(it) }
            found.sort_by { [it.max, -it.count(&:positive?)] }
          end

          def counts(rows, index, split, &)
            return yield(split) if index == @tables.size && rows.zero?
            return if index == @tables.size

            [rows, MAX_PER_TABLE].min.downto(0) { counts(rows - it, index + 1, split + [it], &) }
          end

          def viable?(split)
            @tables.each_with_index.all? do |table, i|
              split[i].zero? || @keys[table].all? do |key|
                key.parent == table || @plan.fk_nullable?(key) || split[@tables.index(key.parent)].positive?
              end
            end
          end

          # Each choice of kind multisets, one per table, whose costs add up
          # to cost.
          def choose(split, index, cost, choice, &)
            return (yield choice if cost.zero?) if index == @tables.size

            table = @tables[index]
            (0..[cost, MAX_COST * split[index]].min).each do |spent|
              multisets(table, split[index], spent) do |kinds|
                choose(split, index + 1, cost - spent, choice.merge(table => kinds), &)
              end
            end
          end

          # Each multiset of count kinds of table that costs exactly cost.
          def multisets(table, count, cost)
            groups = groups(table)
            (0..count).each do |twos|
              ones = cost - (MAX_COST * twos)
              zeros = count - ones - twos
              next if ones.negative? || zeros.negative?

              groups[1].repeated_combination(ones) do |a|
                groups[2].repeated_combination(twos) { |b| yield [*([0] * zeros), *a, *b] }
              end
            end
          end

          def groups(table)
            kind = @kinds.fetch(table)
            kind.kinds.each_index.group_by { kind.cost(it) }.then { |g| [g[0] || [], g[1] || [], g[2] || []] }
          end

          # The rows of a kind choice, then each wiring of their foreign keys.
          def wire(choice, &)
            rows = rows(choice)
            slots = rows.flat_map { |row| @keys[row.table].map { [row, it] } }
            assign(slots, 0, rows.group_by(&:table)) do
              yield unique(rows.map { Generator::Row.new(it.table, it.cells.dup) })
            end
          end

          def rows(choice)
            fresh = 0
            @tables.flat_map do |table|
              keys = pk_values(table, choice.fetch(table).size)
              rows = choice.fetch(table).each_with_index.map { |kind, nth| row(table, kind, keys, nth, fresh += 1) }
              distinct(table, rows, fresh)
            end
          end

          def row(table, kind, keys, nth, fresh)
            cells = @plan.entries_for(table).to_h { [it.column, fixed(table, it, keys, nth, fresh)] }
            Generator::Row.new(table, cells.reject { |_, v| v == :none }.merge(@kinds[table].kinds[kind]))
          end

          # A kind gives a :pk the queries compare with a constant its value
          # (Kinds), so a row can repeat an earlier row's. It gets the first
          # next unique value no earlier row holds here, before a foreign key
          # points at it; Uniques catches one that still repeats.
          def distinct(table, rows, fresh)
            @plan.entries_for(table).select { it.kind == :pk }.each { freshen(table, it.column, rows, fresh) }
            rows
          end

          def freshen(table, column, rows, fresh)
            taken = Set.new
            rows.each do |row|
              next if taken.add?(row.cells[column])

              fresh = untaken(table, column, taken, fresh)
              taken << row.cells[column] = @domains.unique(table, column, fresh)
            end
          end

          # The nth after fresh whose unique value isn't taken, or, when a
          # CHECK pins the column to values all taken, the last one tried:
          # one try more than taken has values finds a free one otherwise.
          def untaken(table, column, taken, fresh)
            ((fresh + 1)..).find { |n| n > fresh + taken.size || !taken.include?(@domains.unique(table, column, n)) }
          end

          # An entry's one value in the nth row, or :none for a column a kind
          # or a foreign key fills.
          def fixed(table, entry, keys, nth, fresh)
            case entry.kind
            when :null then nil
            when :pk then keys.dig(entry.column, nth) || @domains.unique(table, entry.column, fresh)
            when :unique then @domains.unique(table, entry.column, fresh)
            when :required then @domains.typical(table, entry.column).first
            else :none
            end
          end

          def unique(rows)
            fresh = rows.size
            uniques = Generator::Uniques.new(@catalog, @plan, ->(t, c) { @domains.unique(t, c, fresh += 1) })
            rows.select { uniques.admit?(it) }
          end

          def pk_values(table, count)
            @plan.entries_for(table).select { it.kind == :pk }.to_h do |entry|
              [entry.column, (@domains.class_values(table, entry.column) +
                              @domains.base_keys(table, entry.column)).uniq.first(count)]
            end
          end

          def assign(slots, index, by_table, &)
            return yield if index == slots.size

            row, key = slots[index]
            parents(key, by_table).each do |parent|
              point(row, key, parent)
              assign(slots, index + 1, by_table, &)
            end
          end

          def point(row, key, parent)
            key.columns.zip(key.parent_columns).each { |c, p| row.cells[c] = parent&.cells&.[](p) }
          end

          # The rows a key can point to, and NULL where it allows it.
          def parents(key, by_table) = by_table.fetch(key.parent, []) + (@plan.fk_nullable?(key) ? [nil] : [])
        end
      end
    end
  end
end
