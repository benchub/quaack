# frozen_string_literal: true

require "pg_query"
require_relative "table_name"
require_relative "index_candidate"
require_relative "statistics"
require_relative "supported_sql"

module Quaack
  module Enclave
    # Generator one (README 5a-1): index candidates from the parse of the
    # query alone, with the statistics input to rank columns.
    #
    #   GeneratorOne.candidates(PgQuery.parse(sql), statistics)
    #   # => [IndexCandidate, ...], each with sources: [:parse]
    #
    # The query must use only what SupportedSql lists, or it raises
    # SupportedSql::Error. So it's one SELECT, with no SELECT ... INTO and
    # no data-modifying CTE. It also must not be a set operation, and every
    # relation must be schema qualified except a reference to a CTE whose
    # name reaches it: the rest of its SELECT, later CTEs in the same WITH,
    # and, under WITH RECURSIVE, every CTE there. The limits must be an Integer max_key_columns of at least
    # 1, a finite brin_min_correlation in 0..1, and a finite
    # brin_min_reltuples. Anything else raises ArgumentError, and no message
    # quotes the SQL. A table with no statistics raises KeyError. The result
    # is ordered and has no duplicates. The same input always gives the same
    # result.
    #
    # Which tables. Only the plain tables in the top-level FROM clause,
    # including joins, get candidates. Each one gets its own, and so does
    # each alias of a self-join. Tables inside a subquery, a CTE, or a
    # subquery in WHERE or the select list get none, though they're still
    # checked for qualification. A subquery or function in FROM has no table's columns, so its columns
    # are skipped, but a join to one still counts for the table on the other
    # side.
    #
    # Which columns. A column qualified by an alias, a table name without an
    # alias, or schema and table belongs to that table. An unqualified one
    # belongs to the one top-level table whose column_names has it. A column
    # that's ambiguous, unknown, or not a table's is skipped, so an
    # unqualified JOIN ... USING column that both sides have is skipped. The
    # column must be bare: under a cast, a COLLATE, or in an expression, it
    # doesn't count.
    #
    # Which predicates. Only the top-level AND conjuncts of WHERE and of each
    # JOIN ... ON count. Anything under OR or NOT is ignored. A constant is a
    # literal, a parameter ($1), or a cast of either.
    #
    # Outer joins. An outer join makes a table nullable when the table is on
    # its nullable side, at any depth: the right of LEFT, the left of RIGHT,
    # or either side of FULL. Every predicate read here is strict except IS
    # NULL. When a strict qual above an outer join rejects the nulls on its
    # nullable side, Postgres turns a LEFT or RIGHT JOIN inner, and a FULL
    # JOIN into a LEFT or RIGHT JOIN that keeps the qual's side, then
    # pushes the qual down to that side's scan. So an IS NULL
    # that touches a table made nullable by an outer join below it is
    # skipped: in WHERE, by any outer join; in an ON, by an outer join
    # under that join. An anti-join's IS NULL is the usual case. Other
    # conjuncts count, in WHERE or in an inner join's ON. An outer join's
    # own ON is stricter: a conjunct counts only when it touches both
    # sides, or only the side that isn't preserved (the right of LEFT, the
    # left of RIGHT). One that touches only a preserved side is a join
    # filter, not a scan filter, so a FULL JOIN's ON keeps only its join
    # conditions. USING always counts.
    # - Equality: col = constant (either side), col IN (constants),
    #   col = ANY(constant array or parameter), and col IS NULL.
    # - Join: a.x = b.y between two tables counts as equality on both. So
    #   does JOIN ... USING (x), for the one table under each side that has
    #   x. NATURAL JOIN doesn't count.
    # - Range: <, <=, >, >= against a constant, BETWEEN (and BETWEEN
    #   SYMMETRIC) with constant bounds, and col LIKE 'constant' when the
    #   pattern isn't empty and its first character isn't %, _, or a
    #   backslash. A LIKE with ESCAPE doesn't count. A btree only serves that
    #   LIKE under the C collation or text_pattern_ops, which this shape
    #   can't express, so 5a-4 finds out whether the planner uses it. A
    #   column with both an equality and a range predicate is equality.
    #
    # - Keyset: a row comparison, (a, b) < ($1, $2) with <, <=, >, or >=,
    #   whose one row is bare columns of one table and whose other row is
    #   constants. (a, b) = (x, y) counts as a = x and b = y. <> doesn't
    #   count.
    #
    # Building the key. Equality columns come first, most selective first:
    # TableStatistics#equality_selectivity, or null_frac for a column whose
    # only predicate is IS NULL. Unknown selectivity goes last. Ties, and
    # the unknowns, keep query order. Then comes at most one range column:
    # the first comparison (<, <=, >, >=, BETWEEN) in query order, or, when
    # there's none, the first prefix LIKE. Then the ORDER BY columns, when
    # ORDER BY can join the key (see OrderTail). When it can, but doesn't
    # start with the range column, there are two keys: one with the range
    # column and one with the ORDER BY columns, because a scan can't both
    # narrow by the range and come out sorted. Each key is capped at
    # max_key_columns, and every leading prefix is its own candidate,
    # shortest first. A keyset takes the range column's place with its
    # columns in order, less any equality columns, and the ORDER BY key
    # stands alone when it starts with them. Only the first keyset on a
    # table counts.
    #
    # Join columns. Each table's keys are built twice: once with its join
    # columns (a join condition or USING) counted as equality columns, and
    # once with them left out, so the key leads with the filters, range,
    # and ORDER BY. A column that a filter also names stays in both. The
    # join-led candidates come first, then the join-free ones, then BRIN.
    # Repeats are dropped, keeping the first, so a table with no join
    # columns gets each candidate once.
    #
    # INCLUDE. Each btree candidate, prefixes too, INCLUDEs the table's
    # select-list and GROUP BY columns that aren't in its own key, in query
    # order. * and t.* mean every column. WHERE, HAVING, and ORDER BY
    # columns outside the key aren't added.
    #
    # BRIN. For each comparison range column (not a prefix LIKE, which BRIN
    # can't serve) whose |correlation| is at least
    # brin_min_correlation, on a table whose reltuples is at least
    # brin_min_reltuples, there's also a single-column BRIN, with no
    # ordering and no INCLUDE. It comes after the table's btrees.
    #
    # No candidate has a predicate or is unique.
    module GeneratorOne
      module_function

      def candidates(parse, statistics, max_key_columns: 3, brin_min_correlation: 0.9, brin_min_reltuples: 1_000_000)
        limits = { max_key_columns:, brin_min_correlation:, brin_min_reltuples: }
        Input.check_limits(limits)
        select = Input.select(parse)
        scope = Scope.new(select, statistics)
        uses = Uses.new(select, scope)
        scope.tables.flat_map { |table| TableCandidates.new(table, uses, limits).to_a }.uniq
      end

      # Checks the input and finds its one SELECT.
      module Input
        module_function

        def check_limits(limits)
          cap = limits[:max_key_columns]
          raise ArgumentError, "max_key_columns must be an Integer of at least 1, got #{cap.inspect}" unless
            cap.is_a?(Integer) && cap >= 1

          check_number(:brin_min_correlation, limits[:brin_min_correlation], 0..1)
          check_number(:brin_min_reltuples, limits[:brin_min_reltuples], nil..nil)
        end

        def check_number(what, value, range)
          return if value.is_a?(Numeric) && value.real? && value.finite? && range.cover?(value)

          raise ArgumentError, "#{what} must be a finite number in #{range}, got #{value.inspect}"
        end

        # SupportedSql makes sure it's one SELECT, with no SELECT ... INTO
        # and no data-modifying CTE.
        def select(parse)
          raise ArgumentError, "expected a pg_query parse result" unless parse.is_a?(PgQuery::ParserResult)

          SupportedSql.check!(parse)
          select = parse.tree.stmts.first.stmt.select_stmt
          raise ArgumentError, "generator one doesn't take a set operation (UNION, INTERSECT, EXCEPT)" if set?(select)

          check_relations(select, [])
          select
        end

        def set?(select) = select.op != :SETOP_NONE

        # Every relation must name its schema, except a reference to a CTE
        # whose name reaches it.
        def check_relations(node, ctes)
          case node
          when PgQuery::RangeVar then check_range(node, ctes)
          when PgQuery::SelectStmt then check_select(node, ctes)
          else children(node).each { |child| check_relations(child, ctes) }
          end
        end

        def children(node)
          case node
          when Google::Protobuf::RepeatedField then node.to_a
          when Google::Protobuf::MessageExts then node.class.descriptor.map { |field| field.get(node) }
          else []
          end
        end

        def check_range(range, ctes)
          return unless range.schemaname.empty? && !ctes.include?(range.relname)

          raise ArgumentError, "relation #{range.relname} isn't schema qualified"
        end

        # A CTE's name reaches the rest of its SELECT, and later CTEs in the
        # same WITH. Under WITH RECURSIVE, it reaches every CTE there,
        # itself included.
        def check_select(select, ctes)
          names = select.with_clause ? check_ctes(select.with_clause, ctes) : []
          select.class.descriptor.each do |field|
            check_relations(field.get(select), ctes + names) unless field.name == "with_clause"
          end
        end

        # Checks each CTE's body and returns the CTE names.
        def check_ctes(with, ctes)
          exprs = with.ctes.map(&:common_table_expr)
          names = exprs.map(&:ctename)
          exprs.each_with_index do |expr, i|
            check_relations(expr.ctequery, ctes + (with.recursive ? names : names.first(i)))
          end
          names
        end
      end

      # One table in the top-level FROM clause. refname is what a qualified
      # column uses: the alias, or else the table's own name.
      Table = Struct.new(:refname, :aliased, :name, :stats)

      # One JOIN: its type, its ON clause, the tables under each side, and
      # which of those an outer join below it already made nullable. An
      # outer join's nullable side is the right for LEFT, the left for
      # RIGHT, and both for FULL. Its preserved side is the other one, and
      # both for FULL.
      Join = Struct.new(:type, :quals, :left, :right, :nullable_below) do
        def nullable
          case type
          when :JOIN_LEFT then right
          when :JOIN_RIGHT then left
          when :JOIN_FULL then left + right
          else []
          end
        end

        # Whether an ON conjunct that touches these tables filters a scan.
        # For an inner join, it always can. For an outer join, it can when
        # it joins the two sides, or when it touches only a side that isn't
        # preserved: the right of a LEFT JOIN or the left of a RIGHT JOIN.
        # A FULL JOIN preserves both sides, so only its join conditions
        # count.
        def keeps?(touched)
          return true if type == :JOIN_INNER

          on = [left, right].map { |side| touched.any? { |t| side.include?(t) } }
          on == [true, true] || on == { JOIN_LEFT: [false, true], JOIN_RIGHT: [true, false] }[type]
        end
      end

      # The tables of the top-level FROM clause, the join clauses between
      # them, and how column references resolve to them.
      class Scope
        attr_reader :tables, :joins, :using

        def initialize(select, statistics)
          @statistics = statistics
          @tables = []
          @joins = []
          @using = []
          @nullable = Set.new.compare_by_identity
          select.from_clause.each { |item| read_item(item) }
        end

        # On the nullable side of some outer join.
        def nullable?(table) = @nullable.include?(table)

        # The tables whose columns an expression names.
        def touched(node) = ColumnRefs.in(node).filter_map { |ref| column(ref)&.first }

        # The [table, column] pairs a ColumnRef means: one pair, one per
        # column for a star, or none when it doesn't resolve.
        def columns(ref)
          *qualifier, name = ref.fields.map { |f| f.a_star ? :* : f.string.sval }
          owners = owners(qualifier)
          return owners.flat_map { |t| t.stats.column_names.map { |c| [t, c] } } if name == :*

          owner(owners, name)
        end

        # The one [table, column] pair a ColumnRef that isn't a star means,
        # or nil.
        def column(ref) = (columns(ref).first if ref.fields.none?(&:a_star))

        private

        # Adds the tables under one FROM item, and returns them.
        def read_item(item)
          if item.join_expr then read_join(item.join_expr)
          elsif item.range_var && !item.range_var.schemaname.empty? then [add_table(item.range_var)]
          else []
          end
        end

        def read_join(join)
          left = read_item(join.larg)
          right = read_item(join.rarg)
          add_join(join, left, right)
          join.using_clause.each { |name| @using << [name.string.sval, left, right] }
          left + right
        end

        def add_join(join, left, right)
          below = (left + right).select { |table| nullable?(table) }
          @joins << Join.new(join.jointype, join.quals, left, right, below)
          @nullable.merge(@joins.last.nullable)
        end

        def add_table(range)
          alias_name = range.alias&.aliasname
          name = TableName.new(schema: range.schemaname, name: range.relname)
          table = Table.new(alias_name || range.relname, !alias_name.nil?, name, @statistics.table(name))
          @tables << table
          table
        end

        def owner(owners, name)
          found = owners.select { |t| t.stats.column_names.include?(name) }
          found.one? ? [[found.first, name]] : []
        end

        def owners(qualifier) = qualifier.empty? ? tables : tables.select { |t| names?(t, qualifier) }

        def names?(table, qualifier)
          case qualifier
          in [refname] then table.refname == refname
          in [schema, relname] then !table.aliased && table.name == TableName.new(schema:, name: relname)
          else false
          end
        end
      end

      # A keyset row comparison, (a, b) < ($1, $2).
      module Keyset
        module_function

        # The [table, column] pairs of one row, in order, when each is a
        # bare column of the same table and the other row is all
        # constants. Either row may hold the columns. Otherwise nil.
        def columns(rows, scope)
          items, values = constants?(rows.first) ? rows.reverse : rows
          return nil unless constants?(values)

          pairs = items.map { |item| pair(item, scope) }
          pairs if one_table?(pairs)
        end

        def one_table?(pairs) = pairs.all? && pairs.map(&:first).uniq(&:object_id).one?

        def constants?(items) = items.all? { |item| constant?(item) }

        def pair(item, scope) = item.column_ref && scope.column(item.column_ref)

        # A literal, a parameter, or a cast of either.
        def constant?(node)
          return constant?(node.type_cast.arg) if node.type_cast

          !(node.a_const || node.param_ref).nil?
        end
      end

      # Each table's columns in some role, in query order, once each.
      class Columns
        def initialize = @lists = Hash.new { |h, k| h[k] = [] }.compare_by_identity

        def add((table, name)) = @lists[table] |= [name]

        def [](table) = @lists[table]
      end

      # Reads the WHERE and JOIN ... ON conjuncts into equality and range
      # columns. It records how each equality column is held: :one (= const,
      # or IN with one item), :null (IS NULL), :many (IN, = ANY), or :join
      # (a join condition or USING).
      class Predicates
        RANGE_OPERATORS = %w[< <= > >=].freeze

        attr_reader :equality, :range, :like, :keysets

        def initialize(scope)
          @scope = scope
          @equality = Columns.new
          @range = Columns.new
          @like = Columns.new
          @keysets = Hash.new { |h, k| h[k] = [] }.compare_by_identity
          @kinds = Hash.new { |h, k| h[k] = [] }
        end

        # The kinds of equality predicate on one table's column.
        def kinds(table, name) = @kinds[[table.object_id, name]]

        # Reads one conjunct. Anything under OR or NOT is ignored.
        def read(node)
          if node.null_test then read_null_test(node.null_test)
          elsif node.a_expr then read_expression(node.a_expr)
          end
        end

        # JOIN ... USING (x): x on the one table under each side that has it.
        def read_using(name, left, right)
          [left, right].each do |side|
            owners = side.select { |t| t.stats.column_names.include?(name) }
            add_equality_pair([owners.first, name], :join) if owners.one?
          end
        end

        private

        def read_null_test(test)
          add_equality(test.arg.column_ref, :null) if test.nulltesttype == :IS_NULL
        end

        def read_expression(expr)
          operator = expr.name.map { |n| n.string.sval }.join(".")
          case expr.kind
          when :AEXPR_OP then read_operator(operator, expr)
          when :AEXPR_IN then read_in(operator, expr)
          when :AEXPR_OP_ANY then read_any(operator, expr)
          when :AEXPR_BETWEEN, :AEXPR_BETWEEN_SYM then read_between(expr)
          when :AEXPR_LIKE then read_like(operator, expr)
          end
        end

        def read_operator(operator, expr)
          if expr.lexpr.row_expr && expr.rexpr.row_expr then read_rows(operator, expr)
          elsif operator == "=" then read_equals(expr.lexpr, expr.rexpr)
          elsif RANGE_OPERATORS.include?(operator) then add_range(against_constant(expr.lexpr, expr.rexpr))
          end
        end

        def read_equals(left, right)
          if left.column_ref && right.column_ref then read_join_condition(left.column_ref, right.column_ref)
          else add_equality(against_constant(left, right), :one)
          end
        end

        # (a, b) = (x, y) is a = x and b = y. (a, b) < (x, y), or another
        # range operator, is a keyset (see Keyset).
        def read_rows(operator, expr)
          rows = [expr.lexpr, expr.rexpr].map { |side| side.row_expr.args.to_a }
          return rows.transpose.each { |l, r| read_equals(l, r) } if operator == "="

          add_keyset(Keyset.columns(rows, @scope)) if RANGE_OPERATORS.include?(operator)
        end

        def add_keyset(pairs) = pairs && (@keysets[pairs.first.first] << pairs.map(&:last))

        def read_in(operator, expr)
          items = expr.rexpr.list.items
          return unless operator == "=" && items.all? { |item| constant?(item) }

          add_equality(expr.lexpr.column_ref, items.one? ? :one : :many)
        end

        def read_any(operator, expr)
          add_equality(expr.lexpr.column_ref, :many) if operator == "=" && array_constant?(expr.rexpr)
        end

        def read_between(expr)
          add_range(expr.lexpr.column_ref) if expr.rexpr.list.items.all? { |item| constant?(item) }
        end

        def read_like(operator, expr)
          add_range(expr.lexpr.column_ref, @like) if operator == "~~" && prefix_pattern?(expr.rexpr)
        end

        # a.x = b.y: equality on each side that's a table's column, unless
        # both sides are the same table.
        def read_join_condition(left, right)
          pairs = [@scope.column(left), @scope.column(right)].compact
          return if pairs.size == 2 && pairs[0][0].equal?(pairs[1][0])

          pairs.each { |pair| add_equality_pair(pair, :join) }
        end

        # The ColumnRef of a bare column compared with a constant, on either
        # side, or nil.
        def against_constant(left, right)
          if left.column_ref && constant?(right) then left.column_ref
          elsif right.column_ref && constant?(left) then right.column_ref
          end
        end

        # A NULL literal matches no row under = or a range operator, so it
        # doesn't count.
        def constant?(node) = Keyset.constant?(node) && !null_literal?(node)

        def null_literal?(node) = node.type_cast ? null_literal?(node.type_cast.arg) : node.a_const&.isnull == true

        def array_constant?(node)
          constant?(node) || node.a_array_expr&.elements&.all? { |e| constant?(e) }
        end

        # A constant pattern whose first character matches only itself.
        def prefix_pattern?(node)
          pattern = node.a_const&.sval&.sval
          !pattern.nil? && !pattern.empty? && !%w[% _ \\].include?(pattern[0])
        end

        def add_equality(ref, kind)
          pair = ref && @scope.column(ref)
          add_equality_pair(pair, kind) if pair
        end

        def add_equality_pair(pair, kind)
          @equality.add(pair)
          kinds(*pair) << kind
        end

        def add_range(ref, columns = @range)
          pair = ref && @scope.column(ref)
          columns.add(pair) if pair
        end
      end

      # What the query does with each table's columns.
      class Uses
        def initialize(select, scope)
          @predicates = Predicates.new(scope)
          read_predicates(select, scope)
          scope.using.each { |using| @predicates.read_using(*using) }
          @covered = covered_columns(select, scope)
          @order = OrderBy.new(select, scope)
        end

        def equality(table) = @predicates.equality[table]

        # The first keyset's columns, in order, or nil.
        def keyset(table) = @predicates.keysets[table].first

        # Range columns that aren't also equality columns: the comparisons
        # first, then the prefix LIKEs, which a plain btree may not serve.
        def range(table) = (@predicates.range[table] | @predicates.like[table]) - equality(table)

        # The range columns without the prefix LIKEs, which BRIN can't serve.
        def comparison_range(table) = @predicates.range[table] - equality(table)

        # Held to one value, by = const or IN with one item. Postgres drops
        # such a column from a sort. It doesn't for IS NULL.
        def pinned?(table, name) = @predicates.kinds(table, name).include?(:one)

        # Only ever tested with IS NULL.
        def null_only?(table, name) = @predicates.kinds(table, name).uniq == [:null]

        # Named only by join conditions and USING.
        def join_only?(table, name) = @predicates.kinds(table, name).uniq == [:join]

        # Select-list and GROUP BY columns.
        def covered(table) = @covered[table]

        # The ORDER BY items as [name, direction, nulls], when every item is
        # a column of this table. Otherwise nil.
        def order(table) = @order.for(table)

        private

        # An IS NULL is skipped when it touches a table that an outer join
        # below it made nullable: every outer join, for WHERE, or the ones
        # under the join, for ON. Every other predicate read here is strict,
        # so Postgres makes those outer joins inner and pushes it down. ON
        # conjuncts that Join#keeps? turns down are skipped too.
        def read_predicates(select, scope)
          conjuncts(select.where_clause).each do |node|
            @predicates.read(node) unless null_test_on?(node, scope) { |t| scope.nullable?(t) }
          end
          scope.joins.each { |join| read_on(join, scope) }
        end

        def read_on(join, scope)
          conjuncts(join.quals).each do |node|
            next if null_test_on?(node, scope) { |t| join.nullable_below.include?(t) }

            @predicates.read(node) if join.keeps?(scope.touched(node))
          end
        end

        def null_test_on?(node, scope, &) = !node.null_test.nil? && scope.touched(node).any?(&)

        def conjuncts(node)
          return [] if node.nil?

          bool = node.bool_expr
          bool&.boolop == :AND_EXPR ? bool.args.flat_map { |arg| conjuncts(arg) } : [node]
        end

        def covered_columns(select, scope)
          covered = Columns.new
          (select.target_list.to_a + select.group_clause.to_a).each do |node|
            ColumnRefs.in(node).each { |ref| scope.columns(ref).each { |pair| covered.add(pair) } }
          end
          covered
        end
      end

      # Every ColumnRef in an expression, in query order, except inside a
      # subquery, which has its own FROM.
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

          node.sub_link ? [] : self.in(node.inner)
        end
      end

      # The ORDER BY clause, resolved to columns. An ordinal (ORDER BY 2) or
      # an explicit output alias (ORDER BY total, from SELECT ... AS total)
      # counts when it names a bare column in the select list. An ordinal at
      # or after a * or t.* in the select list doesn't resolve, since the
      # star's width isn't counted. Postgres matches a bare name to an
      # output name before an input column. This matches explicit aliases
      # only, not the implicit names Postgres gives other items.
      class OrderBy
        DIRECTIONS = { SORTBY_DEFAULT: :asc, SORTBY_ASC: :asc, SORTBY_DESC: :desc }.freeze
        NULLS = { SORTBY_NULLS_DEFAULT: nil, SORTBY_NULLS_FIRST: :first, SORTBY_NULLS_LAST: :last }.freeze

        def initialize(select, scope)
          @scope = scope
          @targets = select.target_list.map(&:res_target)
          @items = select.sort_clause.map { |node| item(node.sort_by) }
        end

        def for(table)
          return nil unless @items.all? { |item| item && item[0].equal?(table) }

          # Postgres reads a repeated column only at its first place.
          @items.map { |item| item.drop(1) }.uniq(&:first)
        end

        private

        # [table, name, direction, nulls], or nil for anything but a
        # column with ASC or DESC.
        def item(sort)
          direction = DIRECTIONS[sort.sortby_dir]
          ref = column_ref(sort.node)
          pair = direction && ref && @scope.column(ref)
          pair && [*pair, direction, NULLS.fetch(sort.sortby_nulls)]
        end

        def column_ref(node)
          ordinal = node.a_const&.ival&.ival
          return ordinal_ref(ordinal) if ordinal

          ref = node.column_ref
          target = ref && output_alias(ref)
          target ? target.val.column_ref : ref
        end

        # A star expands to columns this doesn't count, so an ordinal at or
        # after one can't be placed.
        def ordinal_ref(ordinal)
          return nil unless ordinal.positive? && @targets.first(ordinal).none? { |t| star?(t) }

          @targets[ordinal - 1]&.val&.column_ref
        end

        def star?(target) = target.val.column_ref&.fields.to_a.any?(&:a_star)

        def output_alias(ref)
          name = ref.fields.first.string&.sval if ref.fields.one?
          @targets.find { |t| t.name == name }
        end
      end

      # The ORDER BY columns that can follow the equality columns in a key,
      # so the planner can drop the sort. Columns pinned to one value, by =
      # const or IN with one item, drop out of ORDER BY first. IS NULL
      # doesn't pin, since Postgres doesn't drop that column from a sort.
      # The unpinned equality columns that are left sit in the key
      # ascending, in ranked order. For ORDER BY to add columns, it must
      # name all of them first, in key order. (When ORDER BY names only
      # equality columns, there's nothing to add.) Their directions must
      # all be ASC NULLS LAST, for a forward scan, or all DESC NULLS FIRST,
      # for a backward scan, which flips the columns that follow.
      class OrderTail
        def initialize(items, unpinned)
          @items = items
          @unpinned = unpinned
        end

        # The key columns to add, or nil when ORDER BY can't join the key.
        # Either can mean there's nothing to add.
        def columns
          head = @items.take_while { |name, _, _| @unpinned.include?(name) }
          tail = @items.drop(head.size)
          return nil unless head.map(&:first) == @unpinned

          scan = scan_direction(head)
          scan && tail.map { |name, direction, nulls| key_column(name, direction, nulls, scan) }
        end

        private

        def scan_direction(head)
          columns = head.map { |name, direction, nulls| IndexCandidate::KeyColumn.new(name:, direction:, nulls:) }
          if columns.all?(&:default_order?) then :forward
          elsif columns.all? { |c| c.direction == :desc && c.nulls == :first } then :backward
          end
        end

        def key_column(name, direction, nulls, scan)
          column = IndexCandidate::KeyColumn.new(name:, direction:, nulls:)
          return column if scan == :forward

          IndexCandidate::KeyColumn.new(name:, direction: column.direction == :asc ? :desc : :asc,
                                        nulls: column.nulls == :first ? :last : :first)
        end
      end

      # The candidates for one table.
      class TableCandidates
        def initialize(table, uses, limits)
          @table = table
          @stats = table.stats
          @uses = uses
          @limits = limits
        end

        def to_a
          btrees = equality_sets.flat_map { |equality| keys(equality) }
                                .flat_map { |key| (1..key.size).map { |n| btree(key.first(n)) } }
          btrees + brins
        end

        private

        # The ranked equality columns, then the same without the columns only
        # a join condition names, so a key can lead with the filters instead.
        # The two are the same when the table has no join-only columns, and
        # the final uniq drops the repeats.
        def equality_sets
          ranked = ranked_equality
          [ranked, ranked.reject { |name| @uses.join_only?(@table, name) }]
        end

        def keys(equality_names)
          equality = equality_names.map { |name| IndexCandidate::KeyColumn.new(name:) }
          tails(equality_names).map { |tail| (equality + tail).first(@limits[:max_key_columns]) }
        end

        # What follows the equality columns in each full key.
        def tails(equality_names)
          range = range_columns(equality_names)
          range_tail = range.map { |name| IndexCandidate::KeyColumn.new(name:) }
          order_tail = order_columns(equality_names)
          return [range_tail] if order_tail.nil? || order_tail.empty?
          return [order_tail] if range.empty? || order_tail.map(&:name).first(range.size) == range

          [range_tail, order_tail]
        end

        # A keyset's columns that aren't equality columns, or else the first
        # range column, or none.
        def range_columns(equality_names)
          keyset = @uses.keyset(@table)&.-(equality_names)
          return keyset unless keyset.nil? || keyset.empty?

          [@uses.range(@table).first].compact
        end

        def order_columns(equality_names)
          items = @uses.order(@table)
          return nil if items.nil?

          items = items.reject { |name, _, _| @uses.pinned?(@table, name) }
          OrderTail.new(items, equality_names.reject { |name| @uses.pinned?(@table, name) }).columns
        end

        def ranked_equality
          @uses.equality(@table).each_with_index.sort_by do |name, position|
            selectivity = selectivity(name)
            selectivity ? [0, selectivity, position] : [1, 0, position]
          end.map(&:first)
        end

        def selectivity(name)
          return nil unless @stats.column?(name)
          return @stats.column(name).null_frac if @uses.null_only?(@table, name)

          @stats.equality_selectivity(name)
        end

        def btree(key)
          IndexCandidate.new(table: @table.name, key:, include: @uses.covered(@table) - key.map(&:name),
                             sources: [:parse])
        end

        def brins
          return [] unless @stats.reltuples >= @limits[:brin_min_reltuples]

          @uses.comparison_range(@table).select { |name| correlated?(name) }.map do |name|
            IndexCandidate.new(table: @table.name, key: [name], access_method: :brin, sources: [:parse])
          end
        end

        def correlated?(name)
          correlation = @stats.column(name).correlation if @stats.column?(name)
          !correlation.nil? && correlation.abs >= @limits[:brin_min_correlation]
        end
      end

      private_constant :Input, :Table, :Join, :Scope, :Keyset, :Columns, :Predicates, :Uses, :ColumnRefs, :OrderBy,
                       :OrderTail, :TableCandidates
    end
  end
end
