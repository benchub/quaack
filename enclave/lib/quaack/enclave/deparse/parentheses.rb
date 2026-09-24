# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module Deparse
      # Parentheses for the operands that pg_query's deparser leaves bare
      # (20260924-4).
      #
      #   Parentheses.add!(tree)   # => tree, changed so it deparses right
      #
      # The deparser writes (a OR b) IS NULL as a OR b IS NULL, which
      # Postgres reads as a OR (b IS NULL). It gets some operands right, but
      # not all. This walks the tree and wraps each operand whose SQL would
      # bind to something else in an explicit parenthesis node, so the
      # deparser writes the parentheses. The round-trip check in Deparse
      # still compares the tree it parses back with the one it was given,
      # so a case this misses is refused as before.
      #
      # A raw parse tree has no parenthesis node, since the parser drops
      # parentheses. The nearest is A_Indirection, which is what the parser
      # builds for (x)[1]. With no subscripts it deparses as (x), and
      # Postgres parses that back as just x. The deparser writes the
      # parentheses itself only for some kinds of x, so for the rest the
      # wrapper holds a second, bare A_Indirection. See wrap.
      #
      # What needs parentheses follows the precedence list in Postgres's
      # gram.y. Each operand's printed SQL has a loosest operator at its
      # left end and at its right end. For example, a + b * c is loosest at
      # +, at both ends, while NOT a is closed at its left end, since
      # nothing can take a from it there, and a IS NULL is closed at its
      # right end. An operand needs parentheses when the end next to its
      # parent's operator is looser than that operator, or as loose and
      # the operator doesn't associate that way. The lower bound of BETWEEN
      # and both arguments of POSITION are a narrower kind of expression,
      # b_expr, that can't hold AND, OR, NOT, IS, IN, LIKE, BETWEEN, ANY,
      # COLLATE, or AT TIME ZONE at all. A subscript needs parentheses on
      # anything but a column, a $n parameter, or a scalar subquery.
      #
      # Nodes says where each node's operands are. It knows
      # the nodes SupportedSql allows. Anything else is taken to be closed
      # at both ends, and left as the deparser writes it.
      module Parentheses
        # How tightly each operator binds, loosest first, from gram.y.
        OR = 1
        AND = 2
        NOT = 3
        IS = 4          # IS NULL, IS TRUE, IS DISTINCT FROM, and their kin.
        COMPARISON = 5  # < > = <= >= <>
        LIKE = 6        # LIKE, ILIKE, IN, and BETWEEN.
        OPERATOR = 8    # Every other operator, and OPERATOR(schema.op).
        ADD = 9         # + and -
        MULTIPLY = 10   # * / %
        POWER = 11      # ^
        AT = 12         # AT TIME ZONE and AT LOCAL.
        COLLATE = 13
        SIGN = 14       # A leading + or -.
        CAST = 17       # ::
        CLOSED = Float::INFINITY

        # Which levels gram.y declares %left and %right. The others are
        # %nonassoc.
        LEFT_ASSOCIATIVE = [OR, AND, OPERATOR, ADD, MULTIPLY, POWER, AT, COLLATE, CAST].freeze
        RIGHT_ASSOCIATIVE = [NOT, SIGN].freeze

        # The unqualified operators gram.y gives a level of their own. The
        # deparser parenthesizes every operand of theirs that's itself an
        # operator, so the levels matter for what ends an operand, such as
        # the prefix operator at the right of a AT TIME ZONE @ b.
        OPERATORS = {
          "<" => COMPARISON, ">" => COMPARISON, "=" => COMPARISON, "<=" => COMPARISON, ">=" => COMPARISON,
          "<>" => COMPARISON, "+" => ADD, "-" => ADD, "*" => MULTIPLY, "/" => MULTIPLY, "%" => MULTIPLY, "^" => POWER
        }.freeze

        # The operators that ANY and ALL write as LIKE, NOT LIKE, ILIKE,
        # and NOT ILIKE.
        LIKE_OPERATORS = %w[~~ !~~ ~~* !~~*].freeze

        # The loosest operator at each end of an expression's SQL, and
        # whether it's a b_expr.
        Ends = Data.define(:left, :right, :b_expr)
        TIGHT = Ends.new(left: CLOSED, right: CLOSED, b_expr: true)

        # A_Indirection's arguments that the deparser parenthesizes itself.
        SELF_PARENTHESIZED = %i[a_indirection func_call a_expr type_cast row_expr a_array_expr json_func_expr].freeze

        module_function

        def add!(tree)
          visit(tree)
          tree
        end

        # Parenthesizes what's needed inside a value, and returns its Ends.
        def visit(value)
          case value
          when PgQuery::Node then value.inner ? visit(value.inner) : TIGHT
          when Google::Protobuf::RepeatedField then value.each { |item| visit(item) } && TIGHT
          when Google::Protobuf::MessageExts then Nodes.ends_of(value)
          else TIGHT
          end
        end

        # Visits each field not named, for what's inside it. What's in
        # those fields is delimited, as a function's arguments are, so it
        # returns TIGHT.
        def rest(message, *handled)
          message.class.descriptor.each { |field| visit(field.get(message)) unless handled.include?(field.name) }
          TIGHT
        end

        # Visits an operand, and wraps it when it needs parentheses: when an
        # operator at level comes after it and its right end is looser, or
        # comes before it and its left end is.
        def operand(node, level, before: false, after: false)
          ends = visit(node)
          loose = (before && looser?(ends.right, level, LEFT_ASSOCIATIVE)) ||
                  (after && looser?(ends.left, level, RIGHT_ASSOCIATIVE))
          loose ? wrap(node) : ends
        end

        def looser?(open, level, keeps_equal) = open < level || (open == level && !keeps_equal.include?(level))

        # Visits an operand where only a b_expr can go.
        def b_expr(node)
          ends = visit(node)
          ends.b_expr ? ends : wrap(node)
        end

        # Replaces what a PgQuery::Node holds with a parenthesis node that
        # holds it. The deparser writes A_Indirection's parentheses only for
        # SELF_PARENTHESIZED, so anything else gets a second A_Indirection
        # around the first, unless bare, which is for what's already inside
        # an A_Indirection. The deparser can't write an A_Indirection with
        # no subscripts around a column, but a column never needs wrapping.
        def wrap(node, bare: false)
          kind = node.node
          wrapper = PgQuery::A_Indirection.new(arg: PgQuery::Node.new(kind => node.inner))
          unless bare || SELF_PARENTHESIZED.include?(kind)
            wrapper = PgQuery::A_Indirection.new(arg: PgQuery::Node.new(a_indirection: wrapper))
          end
          node.a_indirection = wrapper
          TIGHT
        end

        # The Ends of an operator at level, whose SQL starts with first's
        # and ends with last's.
        def spanning(level, first, last, b_expr: false)
          Ends.new(left: [level, first.left].min, right: [level, last.right].min, b_expr:)
        end

        def infix(left, right, level, b_expr: false)
          before = operand(left, level, before: true)
          after = operand(right, level, after: true)
          spanning(level, before, after, b_expr: b_expr && before.b_expr && after.b_expr)
        end

        def prefix(node, level, b_expr: true)
          ends = operand(node, level, after: true)
          Ends.new(left: CLOSED, right: [level, ends.right].min, b_expr: b_expr && ends.b_expr)
        end

        def postfix(node, level, b_expr: false)
          ends = operand(node, level, before: true)
          Ends.new(left: [level, ends.left].min, right: CLOSED, b_expr: b_expr && ends.b_expr)
        end

        # The level an operator binds at. For ANY and ALL, some are written
        # as LIKE.
        def operator_level(names, subquery: false)
          return OPERATOR unless names.size == 1

          name = names[0].string.sval
          return LIKE if subquery && LIKE_OPERATORS.include?(name)

          OPERATORS.fetch(name, OPERATOR)
        end

        # Where each node's operands are, and what binds them, for
        # Parentheses. Each method visits the node and
        # returns its Ends.
        module Nodes
          extend Parentheses

          RULES = {
            PgQuery::A_Expr => :a_expr, PgQuery::BoolExpr => :bool_expr, PgQuery::NullTest => :test,
            PgQuery::BooleanTest => :test, PgQuery::CollateClause => :collate, PgQuery::TypeCast => :type_cast,
            PgQuery::FuncCall => :func_call, PgQuery::SubLink => :sub_link, PgQuery::A_Indirection => :indirection,
            PgQuery::SelectStmt => :select_stmt
          }.freeze

          A_EXPRS = {
            AEXPR_OP: :operator, AEXPR_DISTINCT: :distinct, AEXPR_NOT_DISTINCT: :distinct, AEXPR_LIKE: :like,
            AEXPR_ILIKE: :like, AEXPR_OP_ANY: :any, AEXPR_OP_ALL: :any, AEXPR_IN: :in_list,
            AEXPR_BETWEEN: :between, AEXPR_NOT_BETWEEN: :between, AEXPR_BETWEEN_SYM: :between,
            AEXPR_NOT_BETWEEN_SYM: :between
          }.freeze

          JUNCTIONS = { AND_EXPR: AND, OR_EXPR: OR }.freeze

          # The functions the parser writes in SQL syntax whose arguments
          # aren't delimited, by name and argument count: AT TIME ZONE,
          # whose arguments are the zone and then the time, AT LOCAL, and
          # POSITION.
          SQL_SYNTAX = { ["timezone", 2] => :at_time_zone, ["timezone", 1] => :at_local,
                         ["position", 2] => :position }.freeze

          # What Postgres subscripts without parentheses.
          SUBSCRIPTED_BARE = %i[column_ref param_ref].freeze

          module_function

          def ends_of(message)
            rule = RULES[message.class]
            rule ? send(rule, message) : rest(message)
          end

          def a_expr(expr)
            rule = A_EXPRS[expr.kind]
            rule ? send(rule, expr) : rest(expr)
          end

          def operator(expr)
            rest(expr, "lexpr", "rexpr")
            return infix(expr.lexpr, expr.rexpr, operator_level(expr.name), b_expr: true) if expr.lexpr

            sign = expr.name.size == 1 && %w[+ -].include?(expr.name[0].string.sval)
            prefix(expr.rexpr, sign ? SIGN : OPERATOR)
          end

          def distinct(expr) = rest(expr, "lexpr", "rexpr") && infix(expr.lexpr, expr.rexpr, IS, b_expr: true)

          def like(expr) = rest(expr, "lexpr", "rexpr") && infix(expr.lexpr, expr.rexpr, LIKE)

          def any(expr) = rest(expr, "lexpr") && postfix(expr.lexpr, operator_level(expr.name, subquery: true))

          def in_list(expr) = rest(expr, "lexpr") && postfix(expr.lexpr, LIKE)

          # a BETWEEN b AND c, where b is a b_expr.
          def between(expr)
            bounds = expr.rexpr&.list&.items.to_a
            return rest(expr) unless expr.lexpr && bounds.size == 2

            low, high = bounds

            rest(expr, "lexpr", "rexpr")
            before = operand(expr.lexpr, LIKE, before: true)
            b_expr(low)
            spanning(LIKE, before, operand(high, LIKE, after: true))
          end

          def bool_expr(expr)
            level = JUNCTIONS[expr.boolop]
            return junction(expr, level) if level && expr.args.any?
            return rest(expr) unless expr.boolop == :NOT_EXPR && expr.args.size == 1

            rest(expr, "args") && prefix(expr.args[0], NOT, b_expr: false)
          end

          # AND or OR, over any number of arguments.
          def junction(expr, level)
            rest(expr, "args")
            last = expr.args.size - 1
            ends = expr.args.each_with_index.map { |arg, i| operand(arg, level, before: i < last, after: i.positive?) }
            spanning(level, ends.first, ends.last)
          end

          # IS NULL, IS TRUE, and their kin.
          def test(node) = rest(node, "arg") && postfix(node.arg, IS)

          def collate(clause) = rest(clause, "arg") && postfix(clause.arg, COLLATE)

          def type_cast(cast) = rest(cast, "arg") && postfix(cast.arg, CAST, b_expr: true)

          # Other calls are delimited.
          def func_call(call)
            rule = SQL_SYNTAX[sql_syntax(call)]
            rule ? rest(call, "args") && send(rule, call.args) : rest(call)
          end

          # A call's name without pg_catalog, and its argument count, when
          # the parser wrote it in SQL syntax.
          def sql_syntax(call)
            schema, name = call.funcname.map { |part| part.string.sval }
            [name, call.args.size] if call.funcformat == :COERCE_SQL_SYNTAX && schema == "pg_catalog"
          end

          def at_time_zone(args) = infix(args[1], args[0], AT)

          def at_local(args) = postfix(args[0], AT)

          def position(args) = args.each { |arg| b_expr(arg) } && TIGHT

          # x IN (SELECT ...), and x op ANY or ALL (SELECT ...). The others
          # are delimited.
          def sub_link(link)
            return rest(link) unless %i[ANY_SUBLINK ALL_SUBLINK].include?(link.sub_link_type) && link.testexpr

            level = link.oper_name.empty? ? LIKE : operator_level(link.oper_name, subquery: true)
            rest(link, "testexpr") && postfix(link.testexpr, level)
          end

          # FETCH FIRST n ROWS WITH TIES, where n must be a c_expr. The
          # deparser parenthesizes most of what isn't, but not x IN, ANY,
          # or ALL (SELECT ...), and it writes a NULL n as ALL, which WITH
          # TIES can't have. Any other LIMIT takes what a WHERE does.
          def select_stmt(stmt)
            rest(stmt, "limit_count")
            count = stmt.limit_count
            ends = visit(count)
            return TIGHT unless stmt.limit_option == :LIMIT_OPTION_WITH_TIES && count&.inner

            wrap(count) if ends != TIGHT || count.a_const&.isnull
            TIGHT
          end

          def indirection(indirection)
            rest(indirection, "arg")
            arg = indirection.arg
            visit(arg)
            wrap(arg, bare: true) unless arg.nil? || subscripted_bare?(arg)
            TIGHT
          end

          # Whether the deparser writes the subscript right without
          # parentheses of ours: what Postgres subscripts bare, a scalar
          # subquery, and what the deparser parenthesizes itself.
          def subscripted_bare?(arg)
            kind = arg.node
            SUBSCRIPTED_BARE.include?(kind) || SELF_PARENTHESIZED.include?(kind) ||
              (kind == :sub_link && arg.sub_link.sub_link_type == :EXPR_SUBLINK)
          end
        end
      end
    end
  end
end
