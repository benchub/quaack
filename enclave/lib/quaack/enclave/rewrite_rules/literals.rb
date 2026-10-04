# frozen_string_literal: true

require_relative "../redaction"

module Quaack
  module Enclave
    module RewriteRules
      # The literal oracle for rules that need to compare placeholders
      # (DESIGN.md 6c). It reads the governed-store placeholder map inside
      # the enclave, but answers only booleans to rule code, and inspect
      # never shows the map.
      class Literals
        def initialize(connection, placeholder_map)
          @connection = connection
          @map = Redaction.checked_map(placeholder_map)
          @next = 0
        end

        # Whether two placeholders hold the same literal: the same value,
        # read as the same type.
        def same?(left, right) = entry(left) == entry(right)

        def holds?(expr)
          name = "quaack_literals_#{@next += 1}"
          expr_holds?(name, expr)
        rescue StandardError
          false
        ensure
          deallocate(name)
        end

        def inspect = "#<#{self.class} placeholders=#{@map.size}, placeholder_map=<redacted>>"

        alias to_s inspect

        def pretty_print(pp) = pp.text(inspect)

        private

        def expr_holds?(name, expr)
          binding = Redaction.binding("SELECT (#{expr}) IS TRUE", @map)
          binding.prepare(@connection, name)
          binding.execute(@connection, name).getvalue(0, 0) == "t"
        end

        def deallocate(name)
          @connection&.exec("DEALLOCATE #{name}") if name
        rescue StandardError
          nil
        end

        def entry(placeholder) = @map[placeholder.to_s]
      end
    end
  end
end
