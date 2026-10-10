# frozen_string_literal: true

require_relative "nulls"

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
      # whichever the column's CHECKs allow. A column a generated
      # column's expression reads gets no boundary values, since the
      # expression could overflow on them (price * qty), and the row
      # wouldn't load. A nullable column whose type
      # has no such value is left NULL when Nulls allows it.
      #
      # A column the query aggregates with max(), min(), sum(), or avg()
      # (see Reads#aggregate) needs a near miss whose value differs from
      # the hit's in the right direction, or loosening the near miss's atom
      # can't change the aggregate (20261010-36). So a near miss's value of
      # its own (apart) applies there even over a DEFAULT, and for a column
      # only min() reads, every other group takes a large value of its own
      # (MIN_APART), so the near miss's smaller one shows. Where a CHECK or
      # the type rejects that value, the column keeps its default or typical
      # value, and vacuity-guard catches an atom left untested.
      class FreeValues
        UNIQUE = Object.new.freeze
        MIN_APART = 999_999

        def initialize(schema, topology, checks, values, reads, &constrained)
          @schema = schema
          @topology = topology
          @checks = checks
          @values = values
          @reads = reads
          @nulls = Nulls.new(schema, values, checks, reads)
          @constrained = constrained
          @varying = {}
        end

        # apart, when given, is a number that tells the row's group from
        # others in a column the query reads: the column takes the type's nth value for it, where it
        # fits, in place of the typical one.
        def value(table, col, mode, apart: nil)
          return unique_value(table, col) if varying(table).include?(col.name)

          apart = aggregate_apart(table, col, apart)
          return default_value(table, col, apart) if col.default

          plain_value(table, col, mode, apart)
        end

        private

        # UNIQUE, or NULL for a type with no distinct value.
        def unique_value(table, col) = null?(table, col) && !@values.distinct?(col) ? nil : UNIQUE

        def plain_value(table, col, mode, apart)
          boundaries = generation_input?(table, col) ? [] : Scenarios.boundaries(col.type, mode)
          boundaries = boundaries.select { @values.readable?(col, it) }
          typical = @values.typical(col)
          # A type with no typical value is refused if no CHECK gives one.
          @checks.satisfying(table, col, [*apart_value(table, col, apart), *boundaries, typical],
                             (@values.refusal(col, table) unless typical))
        rescue Error
          raise if typical || !null?(table, col)

          nil
        end

        # A generation input keeps the typical value, as it gets no
        # boundary value. So does a column the query can't read, where a
        # value of its own would change no result.
        def apart_value(table, col, apart)
          return if apart.nil? || generation_input?(table, col) || !@reads.read?(table, col.name)

          @values.nth(col, apart, table:)
        rescue Error
          nil
        end

        def null?(table, col) = @nulls.allowed?(table, col)

        def aggregate_apart(table, col, apart)
          return apart if apart || @reads.aggregate(table, col.name) != :min

          MIN_APART
        end

        # A defaulted column keeps its default, but an aggregated one takes
        # its value of its own where its CHECKs allow it.
        def default_value(table, col, apart)
          return :omit unless @reads.aggregate(table, col.name)

          value = apart_value(table, col, apart)
          value && @checks.allows?(table, col, value) ? value : :omit
        end

        def generation_input?(table, col) = @schema.constraints(table).generation_inputs.include?(col.name)

        def varying(table)
          @varying[table] ||= @schema.constraints(table).varying(
            @schema.columns(table).select { free?(table, it) }
          ) { [@values.rank(it), @checks.checked?(table, it) ? 1 : 0] }
        end

        # A cut foreign key's column is keyed too: it joins its parent's
        # key class (Topology).
        def free?(table, col)
          !@topology.keyed?(table, col.name) && !%w[generated identity].include?(col.default) &&
            !@constrained.call(@topology.slot(table, col.name))
        end
      end
    end
  end
end
