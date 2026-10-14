# frozen_string_literal: true

require_relative "../../deadline"

module Quaack
  module Enclave
    module Fuzz
      module Enumerate
        # Each footprint table's row kinds: what a row holds in the columns
        # the queries read and the key columns the plan draws (:key), each
        # from the column's value classes. A key the plan fixes by position
        # (:pk) or fills from a parent row (:fk) is Worlds'.
        #
        #   kinds = Kinds.new(catalog, plan, domains)
        #   kinds.for(table)       # => Table(kinds: [{ "status" => "shipped", ... }, ...], base: 4)
        #   kinds.domains(table)   # => { "status" => ["shipped", "new", ..., nil], ... }
        #
        # A column's classes are its base values from Domains, never the
        # world values or copies the fuzz search also draws: a read column's
        # own values (the queries' constants, their neighbours, ValuePools'
        # pools), the queries' first, then two typical ones, at most DOMAIN;
        # a key column's first three key-class values and first two shared
        # keys; and NULL in either when the column allows it or has no other
        # class. The kinds are the base-choice kinds first, a base row (each
        # column's first non-NULL class, which the pools put first because
        # it passes the queries' tests) and then each single-column change
        # of it, then the full product of the columns' classes when it's at
        # most MAX_KINDS, else a pairwise covering array of it: every pair
        # of two columns' classes in some kind.
        #
        # Trust boundary: kinds hold real values, so they stay here.
        class Kinds
          DOMAIN = 8
          MAX_KINDS = 64
          SEED = 7
          TRIES = 25
          TYPICAL = 2
          KEY_CLASS = 3
          KEYS = 2

          # base counts the base-choice kinds at the front of kinds.
          Table = Data.define(:kinds, :base) do
            # A kind's deviation from the base row: 0 for it, 1 for a
            # single-column change of it, 2 for any other.
            def cost(index)
              return 0 if index.zero?

              index < base ? 1 : 2
            end
          end

          def initialize(catalog, plan, domains)
            @catalog = catalog
            @plan = plan
            @domains = domains
            @tables = {}
            @columns = {}
          end

          def for(table) = @tables[table] ||= build(domains(table))

          # Each read or key column's classes, in order.
          def domains(table)
            @columns[table] ||= @plan.entries_for(table).filter_map do |entry|
              values = classes(table, entry) or next
              [entry.column, values]
            end.to_h
          end

          private

          def classes(table, entry)
            values = case entry.kind
                     when :read then read(table, entry.column)
                     when :key then key(table, entry.column)
                     else return
                     end
            values += [nil] if @catalog.column(table, entry.column).nullable || values.empty?
            values
          end

          def read(table, column)
            own = @domains.values(table, column).compact
            (own.first(DOMAIN - TYPICAL) + @domains.typical(table, column).first(TYPICAL) + own).uniq.first(DOMAIN)
          end

          def key(table, column)
            (@domains.class_values(table, column).first(KEY_CLASS) +
              @domains.base_keys(table, column).first(KEYS)).uniq
          end

          def build(domains)
            return Table.new(kinds: [{}], base: 1) if domains.empty?

            base = base_choice(domains)
            rest = if domains.values.map(&:size).reduce(:*) <= MAX_KINDS
                     product(domains)
                   else
                     pairwise(domains, Random.new(SEED))
                   end
            Table.new(kinds: (base + rest).uniq, base: base.size)
          end

          def base_choice(domains)
            base = domains.transform_values { |values| values.find { !it.nil? } || values.first }
            [base] + domains.flat_map { |column, values| (values - [base[column]]).map { base.merge(column => it) } }
          end

          def product(domains)
            names = domains.keys
            first, *rest = domains.values
            first.product(*rest).map { names.zip(it).to_h }
          end

          # A greedy (AETG) pairwise covering array: each kind is the best of
          # TRIES greedy picks at covering pairs not yet covered. On a wide
          # table that takes seconds, so each pick checks the rewrite's
          # Deadline.
          def pairwise(domains, rng)
            names = domains.keys
            uncovered = uncovered(domains, names)
            rows = []
            until uncovered.empty?
              pick = best(domains, names, uncovered, rng)
              names.combination(2).each { |a, b| uncovered.delete(pair(names, a, pick[a], b, pick[b])) }
              rows << names.to_h { [it, domains[it][pick[it]]] }
            end
            rows
          end

          def best(domains, names, uncovered, rng)
            Deadline.check!
            Array.new(TRIES) { greedy(domains, names, uncovered, rng) }.max_by { gained(names, it, uncovered) }
          end

          def uncovered(domains, names)
            set = Set.new
            names.combination(2).each do |a, b|
              domains[a].each_index { |x| domains[b].each_index { |y| set << [a, x, b, y] } }
            end
            set
          end

          def greedy(domains, names, uncovered, rng)
            names.shuffle(random: rng).each_with_object({}) do |name, pick|
              pick[name] = domains[name].each_index.max_by do |x|
                [pick.count { |other, y| uncovered.include?(pair(names, name, x, other, y)) }, rng.rand]
              end
            end
          end

          def gained(names, pick, uncovered)
            names.combination(2).count { |a, b| uncovered.include?(pair(names, a, pick[a], b, pick[b])) }
          end

          # A pair of two columns' class indexes, the columns in names' order.
          def pair(names, one, one_at, two, two_at)
            names.index(one) < names.index(two) ? [one, one_at, two, two_at] : [two, two_at, one, one_at]
          end
        end
      end
    end
  end
end
