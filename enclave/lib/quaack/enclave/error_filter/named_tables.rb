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
        # One part of a name, as the catalog's quote_ident writes it: a bare
        # lowercase name, or a quoted one of printable ASCII (ErrorFilter's
        # shaped? refuses the rest) whose quote marks are doubled.
        PART = /(?:[a-z_][a-z0-9_$]{0,62}|"(?:[^"\x00-\x1f\x7f]|""){1,126}")/
        NAME = /\A#{PART}\.#{PART}\z/

        module_function

        # cycle if it's an Array of SIZES plain schema.name Strings (NAME) whose
        # last is its first, and nil otherwise.
        def check(cycle)
          return unless cycle.instance_of?(Array) && SIZES.cover?(cycle.size) && cycle.first == cycle.last

          cycle if cycle.all? { ErrorFilter.shaped?(it, NAME) }
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
