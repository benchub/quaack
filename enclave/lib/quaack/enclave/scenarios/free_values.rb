# frozen_string_literal: true

module Quaack
  module Enclave
    module Scenarios
      # Values for a table's free columns: ones no key class, atom (from
      # the block, given the column's slot), or cut foreign key sets, and
      # that aren't generated. A column a unique key needs to vary
      # (ArenaSchema::Constraints#varying, preferring a column no CHECK
      # constrains) gets UNIQUE, which Builder#identify turns into a value
      # per distinct row. Any other
      # column with a default is left to it, and the rest get a boundary
      # value, for a boundary group, or the type's typical value,
      # whichever the column's CHECKs allow.
      class FreeValues
        UNIQUE = Object.new.freeze

        def initialize(schema, topology, checks, values, &constrained)
          @schema = schema
          @topology = topology
          @checks = checks
          @values = values
          @constrained = constrained
          @varying = {}
        end

        def value(table, col, mode)
          return UNIQUE if varying(table).include?(col.name)
          return :omit if col.default

          boundaries = Scenarios.boundaries(col.type, mode).select { @values.readable?(col, it) }
          typical = @values.typical(col)
          # A type with no typical value is refused if no CHECK gives one.
          @checks.satisfying(table, col, boundaries + [typical], (@values.refusal(col, table) unless typical))
        end

        private

        def varying(table)
          @varying[table] ||= @schema.constraints(table).varying(
            @schema.columns(table).select { free?(table, it) }
          ) { [@values.rank(it), @checks.checked?(table, it) ? 1 : 0] }
        end

        def free?(table, col)
          !@topology.keyed?(table, col.name) && !%w[generated identity].include?(col.default) &&
            !@topology.cut?(table, col.name) && !@constrained.call(@topology.slot(table, col.name))
        end
      end
    end
  end
end
