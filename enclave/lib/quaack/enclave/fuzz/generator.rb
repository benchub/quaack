# frozen_string_literal: true

require_relative "generator/plan"
require_relative "generator/draw"

module Quaack
  module Enclave
    module Fuzz
      # Random small worlds: rows for the footprint's tables, parents first,
      # from Domains' values.
      #
      #   generator = Generator.new(catalog, domains)
      #   rows = generator.world(rng)   # => [Row(table:, cells: { "id" => "1", ... }), ...]
      #
      # Each world draws its own swarm Config: how many rows each table gets
      # (0 to 4), how small the shared key pool is, and how often a value is
      # NULL, one of the queries' own, a copy of an earlier row's, a type
      # boundary, or one from world knowledge (WorldValues). Different
      # worlds stress different things, which finds more than one fixed mix.
      #
      # A share of worlds (COPIES_SHARE), when the queries hold an integer
      # constant up to WorldValues::COPIES_MAX, give one table Copies: as
      # many rows as a constant or one either side, each a copy of the
      # table's first row in every column but its fresh unique ones and,
      # at the vary rate, one read column the queries don't group or
      # partition on, so a group can mix values in it.
      # A HAVING count, a window frame, a LIMIT or an OFFSET can need them.
      # Half of them (SPREAD_SHARE), when a table has a foreign key to
      # another, spread instead (task 20261113-210241-1): such a table gets
      # copies for every row of the parent its first such key points to,
      # which gets at least SPREAD_PARENTS rows, and the parents take the
      # copy counts in turn (Copies#spread, the counts from a random
      # start), so a parent that passes the queries' other conditions with
      # exactly n children, and one with n+1, both come often. The share
      # is fixed and the counts are the same pool's, so how a world is
      # built never follows a threshold, only the values in it.
      #
      # Each column gets its value the way the Plan says. A row that would
      # collide on a unique key gets a fresh value in one of the key's
      # columns, or is left out (Uniques).
      class Generator
        Row = Struct.new(:table, :cells)
        Config = Data.define(:rows, :key_pool, :null_rate, :literal_bias, :dup_rate, :boundary_rate, :world_rate,
                             :copies)
        Copies = Data.define(:table, :count, :vary, :spread)

        ROWS = [0, 1, 1, 2, 2, 2, 3, 3, 4].freeze
        COPIES_SHARE = 0.25
        SPREAD_SHARE = 0.5
        SPREAD_PARENTS = 8

        attr_reader :catalog, :domains, :plan

        def initialize(catalog, domains)
          @catalog = catalog
          @domains = domains
          @plan = Plan.new(catalog, domains)
          @plan.each_column { |table, column| domains.prepare(table, column) }
        end

        def order = @plan.order

        # The tables with a foreign key to another table, which a spread
        # copies world can spread over.
        def children
          order.select { |table| @plan.entries_for(table).any? { it.kind == :fk && it.fk.parent != table } }
        end

        def self.config(rng, tables, counts = [], children = [], spread = [])
          Config.new(rows: tables.to_h { [it, ROWS.sample(random: rng)] }, key_pool: [1, 2, 2, 3].sample(random: rng),
                     null_rate: [0.0, 0.15, 0.4].sample(random: rng),
                     literal_bias: [0.5, 0.8, 0.95].sample(random: rng), dup_rate: [0.0, 0.0, 0.3].sample(random: rng),
                     boundary_rate: [0.0, 0.0, 0.05].sample(random: rng),
                     world_rate: [0.0, 0.1, 0.3].sample(random: rng),
                     copies: copies(rng, tables, counts, children, spread))
        end

        def self.copies(rng, tables, counts, children = [], spread = [])
          pool = counts.empty? ? spread : counts
          return if pool.empty? || tables.empty? || rng.rand >= COPIES_SHARE

          turns = turns(rng, spread.empty? ? counts : spread, children)
          Copies.new(table: (turns ? children : tables).sample(random: rng), count: pool.sample(random: rng),
                     vary: [0.0, 0.0, 0.1, 0.3].sample(random: rng), spread: turns)
        end

        # A spread world's copy counts, from a random start, at SPREAD_SHARE,
        # else nil. pool is a count threshold's own counts (WorldValues#spread)
        # when the queries compare a count with an integer, else copies'.
        def self.turns(rng, pool, children)
          pool.rotate(rng.rand(pool.size)) if children.any? && rng.rand < SPREAD_SHARE
        end

        def world(rng) = Draw.new(self, rng).rows
      end
    end
  end
end
