# frozen_string_literal: true

module Quaack
  module Enclave
    module Fuzz
      # Walks a pg_query tree as a Hash (tree.to_h) for what the search
      # reads from SQL: the columns an expression names and its constants.
      module Tree
        module_function

        # The names of the columns node refers to, by their last field.
        def column_refs(node, found = [])
          case node
          when Hash
            ref = node[:column_ref]
            name = ref && ref[:fields].last.dig(:string, :sval)
            found << name if name
            node.each_value { column_refs(it, found) }
          when Array then node.each { column_refs(it, found) }
          end
          found
        end

        # Each column reference in node as [name, bare]: name is :star for
        # a *, and bare is whether it's a single name, which may be a
        # whole-row reference to a table.
        def references(node, found = [])
          case node
          when Hash
            fields = node.dig(:column_ref, :fields)
            found << [fields.last.key?(:a_star) ? :star : fields.last.dig(:string, :sval), fields.size == 1] if fields
            node.each_value { references(it, found) }
          when Array then node.each { references(it, found) }
          end
          found
        end

        # The string and number constants in node, as text.
        def constants(node, found = [])
          case node
          when Hash
            constant = node[:a_const]
            value = constant && !constant[:isnull] && value(constant)
            found << value if value
            node.each_value { constants(it, found) }
          when Array then node.each { constants(it, found) }
          end
          found
        end

        def value(constant)
          return (constant[:ival][:ival] || 0).to_s if constant.key?(:ival)

          constant.dig(:sval, :sval) || constant.dig(:fval, :fval)
        end
      end
    end
  end
end
