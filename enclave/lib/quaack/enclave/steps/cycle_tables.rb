# frozen_string_literal: true

module Quaack
  module Enclave
    module Steps
      # The tables of an fk_cycle refusal (Scenarios::Topology), checked
      # against the run's schema before they leave the enclave.
      #
      #   tables = CycleTables.tables(store) # => ["public.orders", "billing.accounts"]
      #   CycleTables.check([%w[public orders], %w[billing accounts], %w[public orders]], tables)
      #   # => ["public.orders", "billing.accounts", "public.orders"]
      #
      # Trust boundary. Table names are schema, not data. check returns
      # only the strings of tables, the schema_subset entry's relations
      # (3b, from the catalog), never a stored value as it is; anything
      # else, or a cycle that doesn't close, gives nil.
      module CycleTables
        # A cycle names at least two tables, and its first table again.
        MIN = 3

        module_function

        # The schema_subset entry's relations as "schema.name", or none if
        # the run hasn't stored it.
        def tables(store)
          return [].freeze unless store.entry?("schema_subset")

          store.read("schema_subset")["tables"].map { |schema, name| "#{schema}.#{name}" }.uniq.freeze
        end

        # cycle's [schema, name] pairs as tables' own strings, or nil.
        def check(cycle, tables)
          return unless closed?(cycle)

          names = cycle.map { table(it, tables) }
          names unless names.include?(nil)
        end

        def closed?(cycle) = cycle.is_a?(Array) && cycle.size >= MIN && cycle.first == cycle.last

        def table(pair, tables)
          return unless pair.is_a?(Array) && pair.size == 2 && pair.all?(String)

          tables.find { it == pair.join(".") }
        end
      end
    end
  end
end
