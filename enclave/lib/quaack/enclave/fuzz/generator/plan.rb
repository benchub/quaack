# frozen_string_literal: true

module Quaack
  module Enclave
    module Fuzz
      class Generator
        # How each footprint column gets its value, and the order tables
        # fill in: parents before children over the kept foreign keys, a
        # cycle cut at a nullable one, whose columns stay NULL.
        #
        # Kinds: :null (a cut key), :fk (from a parent row), :pk (a key
        # class's single-column unique key, one no earlier row took), :key
        # (from the key class's shared pool), :read (from the column's
        # values), :unique (a fresh value) and :required (an ordinary one).
        # A column with no kind takes its default.
        class Plan
          Entry = Data.define(:column, :kind, :fk)
          # A table's foreign keys the plan fills and cuts, and its unique keys.
          Table = Data.define(:name, :kept, :cut, :unique)

          attr_reader :order

          def initialize(catalog, domains)
            @catalog = catalog
            @domains = domains
            @cut = Set.new
            @order = topological
            @entries = @order.to_h { [it, entries(it)] }
          end

          def entries_for(table) = @entries.fetch(table)

          def kind(table, column) = @entries.fetch(table).find { it.column == column }&.kind

          def each_column(&) = @entries.each { |table, entries| entries.each { yield table, it.column } }

          def fk_nullable?(key) = key.columns.all? { @catalog.column(key.child, it).nullable }

          private

          def topological
            edges = @catalog.kept.reject { it.child == it.parent }
            order = []
            remaining = @catalog.footprint.dup
            until remaining.empty?
              ready = ready(edges, remaining)
              next order << remaining.delete(ready) if ready

              edges -= [cut(edges, remaining)]
            end
            order
          end

          def ready(edges, remaining)
            remaining.find { |table| edges.none? { it.child == table && remaining.include?(it.parent) } }
          end

          def cut(edges, remaining)
            within = edges.select { remaining.include?(it.child) && remaining.include?(it.parent) }
            (within.find { fk_nullable?(it) } || within.first).tap { @cut << it }
          end

          def entries(name)
            table = Table.new(name:, kept: @catalog.kept.select { it.child == name && !@cut.include?(it) },
                              cut: @cut.select { it.child == name }.flat_map(&:columns),
                              unique: @catalog.unique_keys(name))
            @catalog.columns(name).filter_map { entry(table, it) }
          end

          def entry(table, col)
            return if col.default == "generated"

            reference = table.kept.find { it.columns.include?(col.name) }
            kind = table.cut.include?(col.name) ? :null : kind_of(table, col, reference)
            Entry.new(column: col.name, kind:, fk: reference) if kind
          end

          def kind_of(table, col, reference)
            return :fk if reference
            return table.unique.include?([col.name]) ? :pk : :key if @domains.key?(table.name, col.name)
            return :read if @domains.read?(table.name, col.name)

            filler(table, col)
          end

          def filler(table, col)
            return :unique if table.unique.flatten.include?(col.name) && (!col.nullable || col.default.nil?)

            :required if !col.nullable && col.default.nil?
          end
        end
      end
    end
  end
end
