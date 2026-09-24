# frozen_string_literal: true

require "pg_query"
require_relative "table_name"

module Quaack
  module Enclave
    # Step 9: the predicate atoms of a query.
    module PredicateAtoms
      Atom = Data.define(:kind, :operator, :negated, :bare, :columns, :shape, :path, :replaceable)
      Column = Data.define(:table, :refname, :name)

      module_function

      def extract(parse, column_names:)
        Walker.new(column_names, Redaction.new(parse.tree)).atoms(parse.tree)
      end

      # Stands in for 3g (20260922-23) until it lands: each constant becomes
      # a numbered placeholder, numbered the way PgQuery.normalize numbers
      # them, in query order after the query's own parameters. 3g's
      # placeholder map should take over the numbering here, so a shape
      # names the same $n as the redacted query the driver gets.
      #
      # A constant is any A_Const: numbers, strings, booleans, NULL, bit
      # strings, wherever they sit, including casts, arrays, IN lists, LIKE
      # patterns and ESCAPE characters, and subqueries. A type's modifiers
      # (the 12 of varchar(12), or the field mask of interval minute) stay,
      # as do COLLATE names. They're written in the query's own text, like
      # its column names, and say how a value is typed, not what it is.
      class Redaction
        def initialize(tree)
          constants = []
          params = []
          collect(tree, constants, params)
          base = params.max || 0
          @numbers = constants.sort.each_with_index.to_h { |location, i| [location, base + i + 1] }
        end

        # The atom's SQL, with every constant replaced.
        def shape(node)
          copy = PgQuery::Node.decode(PgQuery::Node.encode(node))
          PgQuery.deparse_expr(replace(copy))
        end

        private

        def collect(node, constants, params)
          case node
          when PgQuery::A_Const then constants << node.location
          when PgQuery::ParamRef then params << node.number
          when PgQuery::TypeName then nil
          when Google::Protobuf::RepeatedField then node.each { |n| collect(n, constants, params) }
          when Google::Protobuf::MessageExts
            node.class.descriptor.each { |f| collect(f.get(node), constants, params) }
          end
        end

        # Replaces each A_Const under the node, in place, and returns it.
        def replace(node)
          case node
          when PgQuery::Node
            return placeholder(node.a_const) if node.a_const

            replace(node.inner)
          when PgQuery::TypeName then nil
          when Google::Protobuf::RepeatedField then node.each_with_index { |n, i| node[i] = replace(n) }
          when Google::Protobuf::MessageExts then replace_fields(node)
          end
          node
        end

        def replace_fields(message)
          message.class.descriptor.each do |field|
            value = field.get(message)
            value.is_a?(PgQuery::Node) ? field.set(message, replace(value)) : replace(value)
          end
        end

        def placeholder(constant)
          PgQuery::Node.new(param_ref: PgQuery::ParamRef.new(number: @numbers.fetch(constant.location, 0)))
        end
      end

      # One relation in a FROM clause, at one query level.
      Rel = Data.define(:level, :refname, :table, :aliased, :columns)

      # Walks the parse and collects the atoms, in query order: each
      # SELECT's WITH first, then its fields in the parse's order.
      class Walker
        def initialize(column_names, redaction)
          @column_names = column_names
          @redaction = redaction
          @atoms = []
        end

        def atoms(tree)
          walk(tree, [], [])
          @atoms
        end

        private

        # scopes is the stack of FROM frames a column can see, innermost
        # last.
        def walk(node, path, scopes)
          case node
          when PgQuery::SelectStmt then select(node, path, scopes)
          when PgQuery::JoinExpr then fields(node, path, scopes, "quals")
          when PgQuery::CaseExpr then case_expr(node, path, scopes)
          when PgQuery::CaseWhen then fields(node, path, scopes, "expr")
          when PgQuery::FuncCall then fields(node, path, scopes, "agg_filter")
          when PgQuery::RangeSubselect, PgQuery::RangeFunction then from_subquery(node, path, scopes)
          when Google::Protobuf::RepeatedField then node.each_with_index { |n, i| walk(n, path + [i], scopes) }
          when Google::Protobuf::MessageExts then fields(node, path, scopes)
          end
        end

        # Walks each field, reading the named ones as predicates.
        def fields(message, path, scopes, *predicates, skip: nil)
          message.class.descriptor.each do |field|
            value = field.get(message)
            next if value.nil? || field.name == skip

            step = path + [field.name]
            predicates.include?(field.name) ? predicate(value, step, scopes) : walk(value, step, scopes)
          end
        end

        # A WITH doesn't see its own SELECT's FROM. Everything else does.
        def select(select, path, scopes)
          walk(select.with_clause, path + ["with_clause"], scopes)
          frame = select.from_clause.flat_map { |item| rels(item, scopes.size) }
          fields(select, path, scopes + [frame], "where_clause", "having_clause", skip: "with_clause")
        end

        # A subquery or function in FROM sees the FROM it's in only when
        # it's LATERAL.
        def from_subquery(item, path, scopes)
          fields(item, path, item.lateral ? scopes : scopes[0...-1])
        end

        # CASE x WHEN v: each WHEN tests x = v.
        def case_expr(expr, path, scopes)
          return fields(expr, path, scopes) unless expr.arg

          walk(expr.arg, path + ["arg"], scopes)
          expr.args.each_with_index do |node, i|
            add_atom(equals(expr.arg, node.case_when.expr), scopes)
            fields(node.case_when, path + ["args", i, "case_when"], scopes)
          end
          walk(expr.defresult, path + ["defresult"], scopes)
        end

        def equals(left, right)
          name = [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))]
          PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name:, lexpr: left, rexpr: right))
        end

        # The relations one FROM item adds to its SELECT's frame.
        def rels(item, level)
          if item.join_expr then join_rels(item.join_expr, level)
          elsif item.range_var then [range_rel(item.range_var, level)]
          elsif item.range_subselect then derived(item.range_subselect.alias&.aliasname, level)
          elsif item.range_function then derived(item.range_function.alias&.aliasname, level)
          else []
          end
        end

        def join_rels(join, level)
          rels(join.larg, level) + rels(join.rarg, level) + derived(join.alias&.aliasname, level)
        end

        def derived(refname, level)
          refname ? [Rel.new(level:, refname:, table: nil, aliased: true, columns: nil)] : []
        end

        # A plain table, or a CTE, whose name has no schema.
        def range_rel(range, level)
          alias_name = range.alias&.aliasname
          table = TableName.new(schema: range.schemaname, name: range.relname) unless range.schemaname.empty?
          Rel.new(level:, refname: alias_name || range.relname, table:, aliased: !alias_name.nil?,
                  columns: table && @column_names.fetch(table))
        end

        # Splits AND, OR, and NOT. Each other expression is an atom, unless
        # it's a bare constant. An atom can hold more atoms, in a subquery
        # or a CASE.
        def predicate(node, path, scopes)
          bool = node.bool_expr
          if bool
            bool.args.each_with_index { |arg, i| predicate(arg, path + ["bool_expr", "args", i], scopes) }
          else
            add_atom(node, scopes) unless constant?(node)
            walk(node, path, scopes)
          end
        end

        def constant?(node) = !(node.a_const || node.type_cast&.arg&.a_const).nil?

        def add_atom(node, scopes)
          columns = ColumnRefs.in(node).filter_map { |ref| Resolver.resolve(ref, scopes) }
          test = Test.of(node)
          kind = kind(test, columns)
          @atoms << Atom.new(kind:, operator: test.operator, negated: kind != :other && test.negated,
                             bare: test.bare?, columns: nil, shape: @redaction.shape(node), path: nil,
                             replaceable: true)
        end

        def kind(test, columns)
          return :join if columns.map(&:first).uniq.size >= 2

          test.family
        end
      end


      # Resolves a ColumnRef to [Rel, name] in a stack of FROM frames,
      # innermost last.
      module Resolver
        module_function

        def resolve(ref, scopes)
          return nil if ref.fields.any?(&:a_star)

          *qualifier, name = ref.fields.map { |f| f.string.sval }
          rel = qualifier.empty? ? unqualified(name, scopes) : qualified(qualifier, scopes)
          rel && [rel, name]
        end

        # The one relation in the innermost frame that can hold it. A frame
        # with a relation whose columns aren't known stops the search.
        def unqualified(name, scopes)
          scopes.reverse_each do |frame|
            found = frame.select { |rel| rel.columns&.include?(name) }
            return found.first if found.one?
            return nil if found.any? || frame.any? { |rel| rel.columns.nil? }
          end
          nil
        end

        def qualified(qualifier, scopes)
          scopes.reverse_each do |frame|
            found = frame.find { |rel| names?(rel, qualifier) }
            return found if found
          end
          nil
        end

        def names?(rel, qualifier)
          case qualifier
          in [refname] then rel.refname == refname
          in [schema, relname] then !rel.aliased && rel.table == TableName.new(schema:, name: relname)
          else false
          end
        end
      end

      # Every ColumnRef in an expression, in query order, except inside a
      # subquery, which has its own FROM. A subquery's test expression
      # (the x of x IN (SELECT ...)) is outside it.
      module ColumnRefs
        module_function

        def in(node)
          case node
          when PgQuery::Node then in_node(node)
          when Google::Protobuf::RepeatedField then node.flat_map { |n| self.in(n) }
          when Google::Protobuf::MessageExts then node.class.descriptor.flat_map { |f| self.in(f.get(node)) }
          else []
          end
        end

        def in_node(node)
          return [node.column_ref] if node.column_ref
          return self.in(node.sub_link.testexpr) if node.sub_link

          self.in(node.inner)
        end

        # No column and no subquery.
        def free?(node) = self.in(node).empty? && !subquery?(node)

        def subquery?(node)
          case node
          when PgQuery::Node then !node.sub_link.nil? || subquery?(node.inner)
          when Google::Protobuf::RepeatedField then node.any? { |n| subquery?(n) }
          when Google::Protobuf::MessageExts then node.class.descriptor.any? { |f| subquery?(f.get(node)) }
          else false
          end
        end
      end

      # What one atom tests, from its syntax: its operator family, its
      # operator, whether the operator negates, the sides that should hold
      # columns, and the sides that should be constant.
      Test = Data.define(:family, :operator, :negated, :operands, :constants) do
        def self.of(node) = Syntax.test(node)

        # Each operand that has a column is a plain column.
        def bare?
          sides = (operands + constants).reject { |side| ColumnRefs.free?(side) }
          sides.any? && sides.all?(&:column_ref)
        end
      end

      # Reads an atom's syntax into a Test.
      module Syntax
        module_function

        RANGE = %w[< <= > >=].freeze
        LIKE = { "~~" => "LIKE", "!~~" => "NOT LIKE", "~~*" => "ILIKE", "!~~*" => "NOT ILIKE" }.freeze
        SIMILAR = { "~" => "SIMILAR TO", "!~" => "NOT SIMILAR TO" }.freeze
        BOOLEAN_TESTS = { IS_TRUE: "IS TRUE", IS_NOT_TRUE: "IS NOT TRUE", IS_FALSE: "IS FALSE",
                          IS_NOT_FALSE: "IS NOT FALSE", IS_UNKNOWN: "IS UNKNOWN",
                          IS_NOT_UNKNOWN: "IS NOT UNKNOWN" }.freeze

        def test(node)
          if node.a_expr then expression(node.a_expr)
          elsif node.null_test then null_test(node.null_test)
          elsif node.boolean_test then other(BOOLEAN_TESTS.fetch(node.boolean_test.booltesttype), [node])
          else other(nil, [node])
          end
        end

        def other(operator, operands) = Test.new(family: :other, operator:, negated: false, operands:, constants: [])

        def null_test(test)
          negated = test.nulltesttype == :IS_NOT_NULL
          checked(:null_test, negated ? "IS NOT NULL" : "IS NULL", negated, [test.arg], [])
        end

        def expression(expr)
          op = expr.name.map { |n| n.string.sval }.join(".")
          case expr.kind
          when :AEXPR_OP then operator(op, expr)
          when :AEXPR_DISTINCT then symmetric(:equality, "IS DISTINCT FROM", true, expr)
          when :AEXPR_NOT_DISTINCT then symmetric(:equality, "IS NOT DISTINCT FROM", false, expr)
          when :AEXPR_LIKE, :AEXPR_ILIKE then one_sided(:like, LIKE.fetch(op), op.start_with?("!"), expr)
          when :AEXPR_SIMILAR then other(SIMILAR.fetch(op), [expr.lexpr, expr.rexpr])
          when :AEXPR_IN then in_list(op, expr)
          when :AEXPR_OP_ANY then quantified(op, "ANY", op == "=", expr)
          when :AEXPR_OP_ALL then quantified(op, "ALL", op == "<>", expr)
          when :AEXPR_BETWEEN, :AEXPR_NOT_BETWEEN, :AEXPR_BETWEEN_SYM, :AEXPR_NOT_BETWEEN_SYM then between(op, expr)
          else other(op, [expr.lexpr, expr.rexpr].compact)
          end
        end

        def operator(op, expr)
          if op == "=" then symmetric(:equality, op, false, expr)
          elsif op == "<>" then symmetric(:equality, op, true, expr)
          elsif RANGE.include?(op) then symmetric(:range, op, false, expr)
          else other(op, [expr.lexpr, expr.rexpr])
          end
        end

        def in_list(op, expr)
          negated = op == "<>"
          checked(:in, negated ? "NOT IN" : "IN", negated, [expr.lexpr], expr.rexpr.list.items.to_a)
        end

        def quantified(op, quantifier, in_list, expr)
          operator = "#{op} #{quantifier}"
          in_list ? one_sided(:in, operator, op == "<>", expr) : other(operator, [expr.lexpr, expr.rexpr])
        end

        def between(op, expr)
          checked(:range, op, op.start_with?("NOT"), [expr.lexpr], expr.rexpr.list.items.to_a)
        end

        def one_sided(family, operator, negated, expr) = checked(family, operator, negated, [expr.lexpr], [expr.rexpr])

        # The column may be on either side.
        def symmetric(family, operator, negated, expr)
          left, right = expr.lexpr, expr.rexpr
          left, right = right, left if ColumnRefs.free?(left)
          checked(family, operator, negated, [left], [right])
        end

        # The family holds when every operand has a column and every
        # constant side is free of columns and subqueries. Otherwise it's
        # other.
        def checked(family, operator, negated, operands, constants)
          fits = operands.none? { |o| ColumnRefs.free?(o) } && constants.all? { |c| ColumnRefs.free?(c) }
          Test.new(family: fits ? family : :other, operator:, negated:, operands:, constants:)
        end
      end

      private_constant :Redaction, :Rel, :Walker, :Resolver, :ColumnRefs, :Test, :Syntax
    end
  end
end
