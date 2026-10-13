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
      # NULL, one of the queries' own, a copy of an earlier row's, or a type
      # boundary. Different worlds stress different things, which finds more
      # than one fixed mix.
      #
      # Each column gets its value the way the Plan says. A row that would
      # collide on a unique key gets a fresh value in one of the key's
      # columns, or is left out (Uniques).
      class Generator
        Row = Struct.new(:table, :cells)
        Config = Data.define(:rows, :key_pool, :null_rate, :literal_bias, :dup_rate, :boundary_rate)

        ROWS = [0, 1, 1, 2, 2, 2, 3, 3, 4].freeze

        attr_reader :catalog, :domains, :plan

        def initialize(catalog, domains)
          @catalog = catalog
          @domains = domains
          @plan = Plan.new(catalog, domains)
          @plan.each_column { |table, column| domains.prepare(table, column) }
        end

        def order = @plan.order

        def self.config(rng, tables)
          Config.new(rows: tables.to_h { [it, ROWS.sample(random: rng)] }, key_pool: [1, 2, 2, 3].sample(random: rng),
                     null_rate: [0.0, 0.15, 0.4].sample(random: rng),
                     literal_bias: [0.5, 0.8, 0.95].sample(random: rng), dup_rate: [0.0, 0.0, 0.3].sample(random: rng),
                     boundary_rate: [0.0, 0.0, 0.05].sample(random: rng))
        end

        def world(rng) = Draw.new(self, rng).rows
      end
    end
  end
end
