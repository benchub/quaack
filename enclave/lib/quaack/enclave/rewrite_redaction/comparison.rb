# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module RewriteRedaction
      # A literal's comparison, the key RewriteRedaction matches by (see
      # there): the innermost A_Expr or FuncCall above it, within one SELECT
      # and outside AND, OR, and NOT, whose other operands name a column.
      module Comparison
        # size is the length of the list the literal's operand is, for an IN
        # list or ARRAY[...], or nil: a list of another length doesn't match,
        # since matching by slot would bind the wrong members.
        Key = Data.define(:operator, :operand, :path, :columns, :size)

        # Where the search for a literal's comparison stops.
        BOUNDARIES = [PgQuery::SelectStmt, PgQuery::BoolExpr, PgQuery::SubLink].freeze

        module_function

        # Yields each message-valued child of message as [field name, index, child].
        def each_child(message)
          message.class.descriptor.each do |field|
            next unless field.type == :message

            value = field.get(message)
            list = field.label == :repeated ? value.to_a : [value]
            list.each_with_index { |child, i| yield field.name, i, child if child }
          end
        end

        def match?(mine, theirs)
          mine && theirs && mine.operator == theirs.operator && mine.operand == theirs.operand &&
            mine.path == theirs.path && mine.size == theirs.size && columns?(mine.columns, theirs.columns)
        end

        # The same columns, in order, a column with no table matching any table's.
        def columns?(mine, theirs)
          mine.size == theirs.size && mine.zip(theirs).all? do |(t1, c1), (t2, c2)|
            c1 == c2 && (t1.nil? || t2.nil? || t1 == t2)
          end
        end

        # The key for a literal below ancestors, or nil.
        def key(ancestors)
          ancestors.each_index.reverse_each do |i|
            message, field, index = ancestors[i]
            break if BOUNDARIES.any? { message.is_a?(it) }

            found = at(message, [field, index], ancestors[(i + 1)..].map { |_, name, n| [name, n] }, ancestors[0...i])
            return found if found
          end
          nil
        end

        # The key if message is the literal's comparison, or nil. operand
        # is the field and index the literal is under, and path the rest of
        # the way down.
        def at(message, operand, path, above)
          operator, others = operands(message, *operand)
          return unless operator

          columns = columns(others, scopes(above))
          Key.new(operator:, operand:, path:, columns:, size: size(message, *operand)) unless columns.empty?
        end

        # The length of the list at message's field, or nil if it isn't one.
        def size(message, field, index)
          node = field == "args" ? message.args[index] : message.public_send(field)
          (node.list&.items || node.a_array_expr&.elements)&.size
        end

        # [operator, the other operands], or nil when message isn't an
        # operator or a function call's argument list.
        def operands(message, field, index)
          case message
          when PgQuery::A_Expr
            [[message.kind, names(message.name)], field == "lexpr" ? message.rexpr : message.lexpr]
          when PgQuery::FuncCall
            [[:func, names(message.funcname)], message.args.to_a.reject.with_index { |_, i| i == index }] if
              field == "args"
          end
        end

        def names(list) = list.map { it.string&.sval }

        # The columns under nodes, outside any subquery, each [table, column], sorted.
        def columns(nodes, scopes)
          refs = []
          Array(nodes).compact.each { collect(it, refs) }
          refs.map { resolve(it, scopes) }.sort_by { |table, column| [column.to_s, table.to_s] }
        end

        def collect(message, refs)
          return if message.is_a?(PgQuery::SubLink) || message.is_a?(PgQuery::SelectStmt)
          return refs << message if message.is_a?(PgQuery::ColumnRef)

          each_child(message) { |_, _, child| collect(child, refs) }
        end

        # [table name or nil, column name]. An alias resolves through the
        # SELECTs from the innermost out; an unqualified column gets the
        # one table of its own SELECT's FROM, if it has just one.
        def resolve(ref, scopes)
          *qualifier, column = ref.fields.map { it.string&.sval }
          [table(qualifier, scopes), column]
        end

        def table(qualifier, scopes)
          return qualifier.last if qualifier.size > 1
          return scopes.reverse_each.lazy.filter_map { it[qualifier.first] }.first if qualifier.size == 1

          only = scopes.last&.values&.uniq
          only.first if only&.size == 1
        end

        # Each SELECT above, outermost first, as { name in FROM => table name or nil }.
        def scopes(above)
          above.filter_map { |message, _, _| from_names(message) if message.is_a?(PgQuery::SelectStmt) }
        end

        def from_names(select) = select.from_clause.each_with_object({}) { |node, names| add_from(node, names) }

        def range_name(range) = range.alias&.aliasname || range.relname

        def add_from(node, names)
          if (range = node.range_var)
            names[range_name(range)] = range.relname
          elsif (join = node.join_expr)
            [join.larg, join.rarg].each { add_from(it, names) }
          elsif (sub = node.range_subselect)&.alias
            names[sub.alias.aliasname] = nil
          end
        end
      end
    end
  end
end
