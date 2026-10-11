# frozen_string_literal: true

module Quaack
  module Enclave
    # The shape check for the tables an error line names (see ErrorFilter).
    # They're schema, never a row value.
    module ErrorFilter
      # A dump_object_unreadable refusal's tables.
      module Tables
        RULE = "dump_object_unreadable"
        SIZES = (1..64)
        # One part of a name, as the catalog's quote_ident writes it: a bare
        # lowercase name, or a quoted one of printable ASCII (ErrorFilter's
        # shaped? refuses the rest) whose quote marks are doubled.
        PART = /(?:[a-z_][a-z0-9_$]{0,62}|"(?:[^"\x00-\x1f\x7f]|""){1,126}")/
        NAME = /\A#{PART}\.#{PART}\z/

        module_function

        # The names of tables that are schema.name Strings of NAME's shape
        # (bare, or quoted as quote_ident writes them), when tables is an
        # Array of SIZES of them. A name that fails the shape check, such as
        # a non-ASCII one, is left out, not the whole field, and nil if none
        # is left.
        def check(tables)
          return unless tables.instance_of?(Array) && SIZES.cover?(tables.size)

          kept = tables.select { ErrorFilter.shaped?(it, NAME) }
          kept unless kept.empty?
        end
      end
    end
  end
end
