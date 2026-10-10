# frozen_string_literal: true

require "pg_query"

module Quaack
  module Driver
    class WinnerSummary
      # Conditions the original query repeats across the arms of one OR or
      # the branches of one UNION (a filter outside a UNION subquery counts
      # as one more branch), and how many times each appears anywhere in the
      # original and in the winner (20261010-37). The winner summary gets
      # these as facts, so it can say a rewrite pulled duplicates out without
      # the LLM having to spot them or guess.
      #
      #   Repeats.of(original_sql, winner_sql)
      #   # => [{ "condition" => "tenant_id = $1", "repeated_across" => "OR arms",
      #   #       "in_original" => 2, "in_winner" => 1 }]
      #
      # A condition is a shape: pg_query's deparse of it with each column
      # reference cut to its column name, so o.state and state match. One
      # that holds a literal is left out, so no value goes in. Either SQL
      # not parsing, or missing, gives an empty list.
      module Repeats
        MOST = 8
        LONGEST = 300
        CONDITIONS = %i[a_expr bool_expr null_test boolean_test sub_link column_ref func_call].freeze

        module_function

        def of(original, winner)
          return [] unless original.is_a?(String) && winner.is_a?(String)

          original_tree = PgQuery.parse(original)
          winner_counts = tally(PgQuery.parse(winner))
          original_counts = tally(original_tree)
          repeated(original_tree).first(MOST).map do |shape, across|
            { "condition" => shape, "repeated_across" => across, "in_original" => original_counts[shape],
              "in_winner" => winner_counts[shape] }
          end
        rescue PgQuery::ParseError
          []
        end

        # Each shape that two or more places of one group hold, with the
        # group's kind, in the order first found.
        def repeated(tree)
          found = {}
          groups(tree).each do |across, places|
            places.flat_map { |conjuncts| conjuncts.filter_map { shape(it) }.uniq }.tally.each do |shape, n|
              found[shape] ||= across if n > 1
            end
          end
          found
        end

        # Each OR's arms and each UNION's branches, as lists of conjuncts.
        def groups(tree)
          groups = []
          tree.walk! do |_parent, _field, node, _location|
            case node
            when PgQuery::BoolExpr
              groups << ["OR arms", node.args.map { conjuncts(it) }] if node.boolop == :OR_EXPR
            when PgQuery::SelectStmt then groups.concat(union_groups(node))
            end
          end
          groups
        end

        def union_groups(select)
          return [["UNION branches", branches(select)]] if select.op == :SETOP_UNION

          select.from_clause.filter_map do |item|
            subquery = item.range_subselect&.subquery&.select_stmt
            next unless subquery&.op == :SETOP_UNION

            ["UNION branches", branches(subquery) + [conjuncts(select.where_clause)]]
          end
        end

        def branches(select)
          return [conjuncts(select.where_clause)] unless select.op == :SETOP_UNION

          branches(select.larg) + branches(select.rarg)
        end

        def conjuncts(node)
          return [] if node.nil?
          return node.bool_expr.args.to_a if node.node == :bool_expr && node.bool_expr.boolop == :AND_EXPR

          [node]
        end

        # How many times each shape appears as a condition anywhere in tree.
        def tally(tree)
          shapes = []
          tree.walk! { |_p, _f, node, _l| shapes << shape(node) if node.is_a?(PgQuery::Node) }
          shapes.compact.tally.tap { it.default = 0 }
        end

        def shape(node)
          return unless CONDITIONS.include?(node.node)

          copy = PgQuery::Node.decode(PgQuery::Node.encode(node))
          return unless strip(copy)

          text = PgQuery.deparse_expr(copy)
          text if text.size <= LONGEST
        rescue PgQuery::ParseError
          nil
        end

        # Cuts each column reference in message to its column name, and
        # whether message holds no literal.
        def strip(message)
          return false if message.is_a?(PgQuery::A_Const)

          cut(message) if message.is_a?(PgQuery::ColumnRef)
          message.class.descriptor.all? do |field|
            value = message[field.name]
            values = field.label == :repeated ? value.to_a : [value]
            values.all? { !it.class.respond_to?(:descriptor) || strip(it) }
          end
        end

        def cut(column_ref)
          last = column_ref.fields.last
          column_ref.fields.clear
          column_ref.fields << last if last
        end
      end
    end
  end
end
