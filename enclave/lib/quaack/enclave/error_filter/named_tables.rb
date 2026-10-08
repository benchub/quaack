# frozen_string_literal: true

module Quaack
  module Enclave
    # The shape checks for the tables some error lines name (see
    # ErrorFilter). Each is schema, never a row value.
    module ErrorFilter
      # An fk_cycle refusal's tables.
      module Cycle
        RULE = "fk_cycle"
        # A cycle names at least two tables and its first again, and at
        # most 64 in all.
        SIZES = (3..64)

        module_function

        # cycle if it's an Array of SIZES plain schema.name Strings whose
        # last is its first, and nil otherwise.
        def check(cycle)
          return unless cycle.instance_of?(Array) && SIZES.cover?(cycle.size) && cycle.first == cycle.last

          cycle if cycle.all? { ErrorFilter.shaped?(it, FUNCTION) }
        end
      end

      # A dump_object_unreadable refusal's tables.
      module Tables
        RULE = "dump_object_unreadable"
        SIZES = (1..64)

        module_function

        # tables if it's an Array of SIZES plain schema.name Strings, and nil
        # otherwise.
        def check(tables)
          tables if tables.instance_of?(Array) && SIZES.cover?(tables.size) &&
                    tables.all? { ErrorFilter.shaped?(it, FUNCTION) }
        end
      end
    end
  end
end
