# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # Swaps nodes in a pg_query tree, in place.
    #
    #   NodeRewrite.each(parse.tree) { |node| replacement_or_nil }
    #
    # It walks the tree in field order, the same order every time, and
    # yields each PgQuery::Node. When the block returns a node, that node
    # takes the old one's place, and neither one's children are walked.
    # When it returns nil, the walk goes on into the old node's children.
    module NodeRewrite
      module_function

      def each(message, &)
        message.class.descriptor.each do |field|
          value = field.get(message)
          case value
          when PgQuery::Node then (swapped = swap(value, &)) && field.set(message, swapped)
          when Google::Protobuf::RepeatedField then each_in_list(value, &)
          when Google::Protobuf::MessageExts then each(value, &)
          end
        end
      end

      def each_in_list(list, &)
        list.each_with_index do |item, i|
          case item
          when PgQuery::Node then (swapped = swap(item, &)) && (list[i] = swapped)
          when Google::Protobuf::MessageExts then each(item, &)
          end
        end
      end

      # What the block returns for node, or nil once node's own children
      # are walked.
      def swap(node, &)
        swapped = yield(node)
        return swapped if swapped

        each(node, &)
        nil
      end
    end
  end
end
