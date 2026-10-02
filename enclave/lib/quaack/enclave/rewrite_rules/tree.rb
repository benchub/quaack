# frozen_string_literal: true

require "pg_query"
require_relative "../rewrite_candidate_check"

module Quaack
  module Enclave
    module RewriteRules
      # What the rules share for reading and building pg_query trees.
      module Tree
        # One name a FROM clause brings into scope: the name itself, its
        # RangeVar if it's a table's, and whether an outer join can fill it
        # with NULLs. name is nil for an item whose name this can't read:
        # a join with an alias, a join type it doesn't know, or anything
        # that isn't a table and has no alias.
        Item = Data.define(:name, :table, :nullable)

        # For each join type, whether its left and right sides are nullable.
        NULLABLE = { JOIN_INNER: [false, false], JOIN_LEFT: [false, true], JOIN_RIGHT: [true, false],
                     JOIN_FULL: [true, true] }.freeze

        # Hands out aliases that no name in the tree uses, and that it
        # hasn't handed out before.
        class Names
          def initialize(tree)
            @taken = Tree.find(tree, PgQuery::String).to_set(&:sval)
          end

          def fresh(base) = (1..).lazy.map { "#{base}_#{it}" }.find { @taken.add?(it) }
        end

        module_function

        # The tree's one statement, when it's a SELECT, or nil. A set
        # operation is one too, with no FROM or WHERE of its own.
        def select(tree)
          stmt = tree.stmts.first.stmt if tree.stmts.size == 1
          stmt.select_stmt if stmt&.node == :select_stmt
        end

        # Every node of type in node, or in an Array of nodes, in tree order.
        def find(node, type)
          node.is_a?(Array) ? node.flat_map { find(it, type) } : RewriteCandidateCheck.nodes(node, type)
        end

        # The conditions a WHERE or ON holds, ANDed: [] for none, and a
        # nested AND's own conditions in its place.
        def conjuncts(node)
          return [] unless node
          return [node] unless node.node == :bool_expr && node.bool_expr.boolop == :AND_EXPR

          node.bool_expr.args.flat_map { conjuncts(it) }
        end

        def all_of(nodes) = bool(:AND_EXPR, nodes)
        def any_of(nodes) = bool(:OR_EXPR, nodes)

        # nil for no nodes, and the node itself for one.
        def bool(boolop, nodes)
          return nodes.first if nodes.size < 2

          PgQuery::Node.new(bool_expr: PgQuery::BoolExpr.new(boolop:, args: nodes))
        end

        def true_const = where_of("SELECT WHERE true")

        # EXISTS (SELECT 1), for the caller to give a FROM and a WHERE.
        def exists = where_of("SELECT WHERE EXISTS (SELECT 1)")

        def where_of(sql) = PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt.where_clause

        # [qualifier, column] for a column written as exactly name.column,
        # or nil.
        def qualified(column_ref)
          fields = column_ref.fields
          fields.map { it.string.sval } if fields.size == 2 && fields.all? { it.node == :string }
        end

        def qualify!(column_ref, qualifier)
          column_ref.fields[0] = PgQuery::Node.new(string: PgQuery::String.new(sval: qualifier))
        end

        # The name a query refers to the table by.
        def refname(range) = range.alias ? range.alias.aliasname : range.relname

        # Whether range is a schema-qualified table read whole: not a CTE
        # (which has no schema), not ONLY, and with no column aliases.
        def plain_table?(range)
          !range.schemaname.empty? && range.inh && (range.alias.nil? || range.alias.colnames.empty?)
        end

        def same_table?(one, other) = [one.schemaname, one.relname] == [other.schemaname, other.relname]

        # The Items of a FROM clause.
        def from_items(nodes, nullable: false) = nodes.flat_map { from_item(it, nullable) }

        def from_item(node, nullable)
          case node.node
          when :range_var then [Item.new(name: refname(node.range_var), table: node.range_var, nullable:)]
          when :join_expr then join_items(node.join_expr, nullable)
          else [Item.new(name: (node.inner.alias&.aliasname if node.inner.respond_to?(:alias)), table: nil, nullable:)]
          end
        end

        def join_items(join, nullable)
          left, right = NULLABLE[join.jointype]
          return [Item.new(name: nil, table: nil, nullable:)] if left.nil? || join.alias

          from_item(join.larg, nullable || left) + from_item(join.rarg, nullable || right)
        end

        # The ON conditions of every join in a FROM clause, which with its
        # WHERE's are all its conditions, or nil unless every join is a
        # plain inner or cross join: not NATURAL, and with no USING.
        def inner_conditions(nodes)
          joins = nodes.flat_map { joins(it) }
          return unless joins.all? { it.jointype == :JOIN_INNER && !it.is_natural && it.using_clause.empty? }

          joins.flat_map { conjuncts(it.quals) }
        end

        def joins(node)
          return [] unless node.node == :join_expr

          [*joins(node.join_expr.larg), *joins(node.join_expr.rarg), node.join_expr]
        end
      end
    end
  end
end
