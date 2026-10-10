# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module Steps
      # The tables of an fk_cycle refusal (Scenarios::Topology), checked
      # against the run's schema before they leave the enclave.
      #
      #   tables = CycleTables.tables(store) # => [["public", "orders"], ["Billing", "accounts"]]
      #   CycleTables.check([%w[public orders], %w[Billing accounts], %w[public orders]], tables)
      #   # => ["public.orders", "\"Billing\".accounts", "public.orders"]
      #
      # Trust boundary. Table names are schema, not data. check returns
      # only strings it builds itself, from the schema and name of a table
      # the schema_subset entry's relations (schema-dump, from the catalog)
      # hold, each part quoted the way the catalog's quote_ident quotes it;
      # a pair that isn't one of those, or a cycle that doesn't close, gives nil.
      module CycleTables
        # A cycle names at least two tables, and its first table again.
        MIN = 3
        BARE = /\A[a-z_][a-z0-9_]*\z/
        # The only keywords quote_ident leaves bare.
        UNQUOTED_KINDS = %i[NO_KEYWORD UNRESERVED_KEYWORD].freeze

        module_function

        # The schema_subset entry's relations as [schema, name] pairs, or
        # none if the run hasn't stored it.
        def tables(store)
          return [].freeze unless store.entry?("schema_subset")

          store.read("schema_subset")["tables"].uniq.freeze
        end

        # cycle's [schema, name] pairs as quoted "schema.name" strings, or nil.
        def check(cycle, tables)
          return unless closed?(cycle)

          names = cycle.map { table(it, tables) }
          names unless names.include?(nil)
        end

        # As quote_ident: a part is left bare only if it's a lowercase name of
        # letters, digits and underscores that isn't a reserved, column-name or
        # type-or-function keyword (an unreserved one such as action stays bare).
        # the catalog would quote.
        def quote(name)
          bare = name.match?(BARE) && PgQuery.scan(name).first.tokens.all? { UNQUOTED_KINDS.include?(it.keyword_kind) }
          bare ? name : %("#{name.gsub('"', '""')}")
        end

        def closed?(cycle) = cycle.is_a?(Array) && cycle.size >= MIN && cycle.first == cycle.last

        # Matches on the schema and the name separately, so a dot in either
        # can't make one table look like another.
        def table(pair, tables)
          return unless pair.is_a?(Array) && pair.size == 2 && pair.all?(String) && tables.include?(pair)

          pair.map { quote(it) }.join(".")
        end
      end
    end
  end
end
