# frozen_string_literal: true

require_relative "../redaction"

module Quaack
  module Enclave
    module RewriteRules
      # The literal oracle for rules that need to compare placeholders
      # (DESIGN.md 6c). It reads the governed-store placeholder map inside
      # the enclave, but answers only booleans to rule code.
      class Literals
        def initialize(connection, placeholder_map, placeholder_shapes)
          @connection = connection
          @map = Redaction.checked_map(placeholder_map)
          @shapes = placeholder_shapes
          @next = 0
        end

        def same?(left, right) = entry(left) == entry(right) && shape(left) == shape(right)

        def holds?(expr)
          name = "quaack_literals_#{@next += 1}"
          expr_holds?(name, expr)
        rescue StandardError
          false
        ensure
          deallocate(name)
        end

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

        def shape(placeholder) = @shapes[placeholder.to_s]&.except("rows")
      end
    end
  end
end
