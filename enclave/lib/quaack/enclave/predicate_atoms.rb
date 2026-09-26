# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "supported_sql"
require_relative "table_name"

module Quaack
  module Enclave
    # Step 9: the predicate atoms of a query, for the value pools and the
    # 9c vacuity guard.
    #
    #   parse = PgQuery.parse(sql)
    #   atoms = PredicateAtoms.extract(parse, column_names: { table_name => ["id", ...] })
    #   PredicateAtoms.with_true(parse, atoms[2])  # => the SQL with that atom replaced by TRUE
    #   PredicateAtoms.node(parse, atoms[2])       # => its pg_query node, real constants and all
    #
    # The parse must use only what SupportedSql lists, so it's one SELECT.
    # Anything else raises SupportedSql::Error. It should already be schema
    # qualified, which 20260922-14 will make sure of before this runs. An
    # unqualified relation here is taken to be a CTE, with unknown columns.
    # column_names gives each plain table's columns, keyed by TableName, so
    # an unqualified column can find its table. A plain table missing from
    # it raises KeyError. Bad input raises ArgumentError. No message quotes
    # the SQL. The result is in query order, and the same input always gives
    # the same result.
    #
    # Where atoms come from. Everywhere: WHERE, every JOIN ... ON, HAVING,
    # an aggregate's FILTER, and each WHEN of a CASE, in any SELECT at any
    # depth, including subqueries, CTEs, and set operations. AND, OR, and
    # NOT are split, and each other expression under them is one atom. NOT
    # isn't part of the atom, so with_true leaves NOT TRUE. A bare constant,
    # such as ON TRUE, isn't an atom, since TRUE can't change it. An atom
    # can hold more atoms, and the outer one comes first. EXISTS (...) holds
    # the ones in its WHERE. Inside an atom, each boolean test is an atom
    # too: a comparison, LIKE, IN, BETWEEN, IS NULL, IS TRUE, or subquery
    # test, and each AND, OR, and NOT is split. So coalesce(x = 1, false),
    # (x = 1) IS NOT FALSE, bool_or(x = 1), and a CASE that returns x = 1
    # each hold the atom x = 1. A select list holds no atoms, even in a
    # subquery inside an atom. A CASE x WHEN v's test is x = v. Each JOIN
    # ... USING column is one atom too. NATURAL JOIN gives none, since its
    # columns aren't written in the query.
    #
    # Kinds. An atom whose columns belong to two or more relations, across
    # query levels too (a correlated subquery's o.id = i.order_id), is
    # :join, whatever its operator. Otherwise the operator picks the kind,
    # when one side has a column and the other has no column and no
    # subquery (a literal, a parameter, now() - interval '1 day'):
    # - :equality: =, <>, IS DISTINCT FROM, IS NOT DISTINCT FROM.
    # - :range: <, <=, >, >=, and BETWEEN in each form, as one atom.
    # - :like: LIKE and ILIKE, with or without NOT or ESCAPE.
    # - :in: IN and NOT IN lists, = ANY, and <> ALL.
    # - :null_test: IS NULL and IS NOT NULL.
    # - :row_comparison: a keyset row comparison, (a, b) < ($1, $2), with
    #   any operator SupportedSql allows for one, as one atom. <> is
    #   negated. Its column side is the row whose elements hold columns,
    #   and bare is true when each element is just a column. Nothing picks
    #   values for it, so the value pools and 3e's literal feeds skip it.
    # - :other: the rest, such as a boolean column, a function call,
    #   EXISTS, x IN (SELECT ...), IS TRUE, other operators, or two
    #   columns of one relation.
    # operator names the test in SQL words ("=", "NOT IN", "BETWEEN", "=
    # ANY", "IS NULL"), or is nil for an atom with no operator. negated is
    # true for the negated form (<>, IS DISTINCT FROM, NOT BETWEEN, NOT
    # LIKE, NOT IN, <> ALL, IS NOT NULL), and false for :other. The column
    # side can be an expression, such as lower(email) or created_at::date.
    # bare is true when every side with a column is just a column.
    #
    # Columns. Each atom lists the columns it names, once each, outside any
    # subquery: a Column with the plain table (a TableName) it belongs to,
    # the name the query calls that table by, and the column name. A column
    # of a subquery, CTE, or function in FROM has no table. One that can't
    # be placed has neither: an unqualified column that more than one table
    # has, or none does, or that a relation with unknown columns might have.
    # Any FROM item but a table or a join, such as a subquery or a
    # function, is a relation with unknown columns, even with no alias.
    # Scoping follows Postgres: an ON sees only its join's inputs, a
    # subquery in FROM sees the FROM it's in only when it's LATERAL, and a
    # function always does, since Postgres makes it LATERAL.
    #
    # Replacing with TRUE. path leads from the parse's tree to the atom's
    # node. with_true copies the tree, puts TRUE there, and deparses it. A
    # simple CASE becomes a searched one, CASE WHEN x = v ..., so one WHEN
    # can be TRUE. A USING column can't be replaced, because USING also
    # merges the two columns into one, so replaceable is false and with_true
    # raises ArgumentError. The deparsed SQL must parse back to the changed
    # tree, or with_true raises Deparse::Error (rule deparse_mismatch). A
    # query with a construct pg_query deparses wrong, such as
    # (a = 1) IS NOT DISTINCT FROM (b AND c), is refused that way for every
    # atom but those that replace the whole construct.
    #
    # Shapes aren't guarded. They're for the report, and they can come out
    # wrong the same way: that atom's shape reads a = $1 IS NOT DISTINCT
    # FROM b AND c.
    #
    # Trust boundary. shape is the only field made from the SQL's text, and
    # it has every literal replaced (see Redaction). The rest hold names,
    # kinds, and a path of field names and indexes, never a value. node and
    # with_true give real values, so what they return stays in the enclave.
    module PredicateAtoms
      Atom = Data.define(:kind, :operator, :negated, :bare, :columns, :shape, :path, :replaceable) do
        # The plain tables its columns belong to, once each.
        def tables = columns.filter_map(&:table).uniq
      end
      Column = Data.define(:table, :refname, :name)

      module_function

      def extract(parse, column_names:)
        tree = select_tree(parse)
        Walker.new(Frames.new(column_names), Redaction.new(tree)).atoms(tree)
      end

      def select_tree(parse)
        raise ArgumentError, "expected a pg_query parse result" unless parse.is_a?(PgQuery::ParserResult)

        SupportedSql.check!(parse)
        parse.tree
      end

      # The query with this one atom replaced by TRUE, deparsed. The parse
      # must be the one the atom came from, and it isn't changed.
      def with_true(parse, atom)
        raise ArgumentError, "a JOIN ... USING column can't be replaced by TRUE" unless atom.replaceable

        tree = Tree.copy(parse.tree)
        case_expr = Tree.simple_case(tree, atom.path)
        if case_expr then SimpleCase.searched(case_expr, atom.path[-3])
        else Tree.set(tree, atom.path, Tree.true_node)
        end
        Deparse.faithfully(tree)
      end

      # The atom's own node in the parse, real constants and all. For a
      # simple CASE's WHEN, that's a new node for its test: x = v. For a
      # USING column, it's the column's name.
      def node(parse, atom)
        case_expr = Tree.simple_case(parse.tree, atom.path)
        return Tree.dig(parse.tree, atom.path) unless case_expr

        SimpleCase.test(case_expr.arg, Tree.dig(parse.tree, atom.path))
      end

      # Paths into a parse tree: field names and list indexes.
      module Tree
        module_function

        # Deparse allows this depth, so a copy should too.
        DEPTH = 1_000

        def copy(message)
          message.class.decode(message.class.encode(message, recursion_limit: DEPTH), recursion_limit: DEPTH)
        end

        # A message's field values, or a list's items.
        def children(node)
          case node
          when Google::Protobuf::RepeatedField then node.to_a
          when Google::Protobuf::MessageExts then node.class.descriptor.map { |field| field.get(node) }
          else []
          end
        end

        def dig(tree, path) = path.reduce(tree) { |node, step| node[step] }

        def set(tree, path, value)
          dig(tree, path[0...-1])[path.last] = value
        end

        def true_node = PgQuery::Node.new(a_const: PgQuery::A_Const.new(boolval: PgQuery::Boolean.new(boolval: true)))

        # The CASE x, when the path leads to one of its WHEN values.
        def simple_case(tree, path)
          return nil unless path.length >= 5 && path.last(5).values_at(0, 1, 3, 4) == %w[case_expr args case_when expr]

          case_expr = dig(tree, path[0...-4])
          case_expr if case_expr.arg
        end
      end

      # CASE x WHEN v THEN ...: each WHEN tests x = v.
      module SimpleCase
        module_function

        def test(arg, value)
          name = [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))]
          PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name:, lexpr: Tree.copy(arg), rexpr: value))
        end

        # Rewrites it, in place, as CASE WHEN x = v ..., with WHEN number
        # index TRUE.
        def searched(case_expr, index)
          case_expr.args.each_with_index do |node, i|
            case_when = node.case_when
            case_when.expr = i == index ? Tree.true_node : test(case_expr.arg, case_when.expr)
          end
          case_expr.arg = nil
        end
      end

      # Stands in for 3g (20260922-23) until it lands: each constant becomes
      # a numbered placeholder, numbered in the order the constants appear in
      # the query's text, after the query's own parameters. That's often,
      # but not always, how PgQuery.normalize numbers them. 3g's placeholder
      # map should take over the numbering here, so a shape names the same
      # $n as the redacted query the driver gets.
      #
      # A constant is any A_Const: numbers, strings, booleans, NULL, bit
      # strings, wherever they sit, including casts, arrays, IN lists, LIKE
      # patterns and ESCAPE characters, and subqueries. A type's modifiers
      # (the 12 of varchar(12), or the field mask of interval minute) stay,
      # as do COLLATE names. They're written in the query's own text, like
      # its column names, and say how a value is typed, not what it is.
      #
      # Some constants aren't values, and stay:
      # - A constant the parser made, which has no location. The parser
      #   makes one for a default it fills in, such as the 1 of FETCH FIRST
      #   ROWS ONLY. It's never text from the query.
      # - EXTRACT's field, such as the epoch of EXTRACT(epoch FROM x), when
      #   it's one of the field names Postgres documents, in any case. It's
      #   a keyword, though the parser stores it as a string, and the query
      #   can write it as one: EXTRACT('epoch' FROM x). Any other string
      #   there is redacted like any other constant.
      #
      # The constructs whose constants needed their own handling here, such
      # as JSON_TABLE paths, CYCLE marks, and normalize's normal form, are
      # refused by SupportedSql before this runs.
      class Redaction
        def initialize(tree)
          constants = []
          params = []
          collect(tree, constants, params)
          base = params.max || 0
          @numbers = constants.sort.each_with_index.to_h { |location, i| [location, base + i + 1] }
        end

        # A column name, quoted when it needs it.
        def self.identifier(name)
          PgQuery.deparse_expr(PgQuery::Node.new(column_ref: PgQuery::ColumnRef.new(
            fields: [PgQuery::Node.new(string: PgQuery::String.new(sval: name))]
          )))
        end

        # The atom's SQL, with every constant replaced, and with the
        # parentheses the deparser leaves out (20260924-4). A shape is only
        # reported, so it isn't checked by parsing it back.
        def shape(node) = PgQuery.deparse_expr(Deparse::Parentheses.add!(replace(Tree.copy(node))))

        private

        def collect(node, constants, params)
          case node
          when PgQuery::A_Const then constants << node.location unless Literals.made?(node)
          when PgQuery::ParamRef then params << node.number
          when PgQuery::TypeName then nil
          else Literals.values(node).each { |child| collect(child, constants, params) }
          end
        end

        # Replaces each A_Const under the node, in place, and returns it.
        def replace(node)
          case node
          when PgQuery::Node then return replace_node(node)
          when Google::Protobuf::RepeatedField then node.each_with_index { |n, i| node[i] = replace(n) }
          when Google::Protobuf::MessageExts then replace_fields(node)
          end
          node
        end

        def replace_node(node)
          return Literals.made?(node.a_const) ? node : placeholder(node.a_const) if node.a_const

          replace(node.inner)
          node
        end

        def replace_fields(message)
          case message
          when PgQuery::TypeName then nil
          when Literals.method(:extract_field?) then message.args[1] = replace(message.args[1])
          else message.class.descriptor.each { |field| replace_field(message, field) }
          end
        end

        def replace_field(message, field)
          value = field.get(message)
          value.is_a?(PgQuery::Node) ? field.set(message, replace(value)) : replace(value)
        end

        def placeholder(constant)
          PgQuery::Node.new(param_ref: PgQuery::ParamRef.new(number: @numbers.fetch(constant.location, 0)))
        end
      end

      # The constants that stay as written (see Redaction).
      module Literals
        module_function

        # The fields of EXTRACT that Postgres documents.
        EXTRACT_FIELDS = %w[
          century day decade dow doy epoch hour isodow isoyear julian microseconds millennium milliseconds minute
          month quarter second timezone timezone_hour timezone_minute week year
        ].to_set.freeze

        # A message's field values, without an EXTRACT field.
        def values(node) = extract_field?(node) ? [node.args[1]] : Tree.children(node)

        # EXTRACT(field FROM x), written in SQL syntax, with a field Postgres
        # documents.
        def extract_field?(node)
          node.is_a?(PgQuery::FuncCall) && node.funcformat == :COERCE_SQL_SYNTAX && node.args.size == 2 &&
            node.funcname.map { |part| part.string.sval } == %w[pg_catalog extract] && field_name?(node.args[0])
        end

        def field_name?(arg)
          text = arg.a_const&.sval
          !text.nil? && EXTRACT_FIELDS.include?(text.sval.downcase)
        end

        # A constant the parser made, not one written in the query, such as
        # the 1 of FETCH FIRST ROWS ONLY. Only these have no location.
        def made?(constant) = constant.location == -1
      end

      # One relation in a FROM clause, at one query level. columns is nil
      # when it isn't a plain table.
      Rel = Data.define(:level, :refname, :table, :aliased, :columns)

      # Builds the Rels a FROM item adds to its SELECT's frame.
      class Frames
        def initialize(column_names)
          @column_names = column_names
        end

        # Anything but a table or a join, such as a subquery or a function,
        # is a relation with unknown columns, named by its alias if it has
        # one. It still counts without one, so an
        # unqualified column stops there instead of resolving outward.
        def rels(item, level)
          if item.join_expr then join_rels(item.join_expr, level)
          elsif item.range_var then [range_rel(item.range_var, level)]
          else [derived(alias_name(item.inner), level)]
          end
        end

        # USING (x): x on the one relation on this side that has it.
        def using_column(name, side)
          found = side.select { |rel| rel.columns&.include?(name) }
          rel = found.first if found.one?
          Column.new(table: rel&.table, refname: rel&.refname, name:)
        end

        private

        # The item is a subquery or a function, since SupportedSql refuses
        # every other kind.
        def alias_name(item) = item.alias&.aliasname

        # A join adds its inputs, and its alias if it has one.
        def join_rels(join, level)
          named = join.alias ? [derived(join.alias.aliasname, level)] : []
          rels(join.larg, level) + rels(join.rarg, level) + named
        end

        def derived(refname, level) = Rel.new(level:, refname:, table: nil, aliased: true, columns: nil)

        # A plain table, or a CTE, whose name has no schema.
        def range_rel(range, level)
          alias_name = range.alias&.aliasname
          table = TableName.new(schema: range.schemaname, name: range.relname) unless range.schemaname.empty?
          Rel.new(level:, refname: alias_name || range.relname, table:, aliased: !alias_name.nil?,
                  columns: table && column_names(table))
        end

        def column_names(table)
          @column_names.fetch(table) { raise KeyError, "no column names for table #{table}" }
        end
      end

      # Walks the parse and collects the atoms, in query order: each
      # SELECT's WITH first, then its fields in the parse's order.
      class Walker
        # The fields that hold a predicate, besides WHERE, HAVING, and ON.
        PREDICATES = { PgQuery::CaseWhen => ["expr"], PgQuery::FuncCall => ["agg_filter"] }.freeze
        # The nodes with their own reading.
        HANDLERS = { PgQuery::SelectStmt => :select, PgQuery::JoinExpr => :join, PgQuery::CaseExpr => :case_expr,
                     PgQuery::RangeSubselect => :from_subquery }.freeze

        def initialize(frames, redaction)
          @frames = frames
          @redaction = redaction
          @atoms = []
          @depth = 0
        end

        def atoms(tree)
          walk(tree, [], [])
          @atoms
        end

        private

        # scopes is the stack of FROM frames a column can see, innermost
        # last.
        def walk(node, path, scopes)
          handler = HANDLERS[node.class]
          if @depth.positive? && Syntax.boolean?(node) then predicate(node, path, scopes)
          elsif handler then send(handler, node, path, scopes)
          elsif node.is_a?(Google::Protobuf::RepeatedField)
            node.each_with_index { |n, i| walk(n, path + [i], scopes) }
          elsif node.is_a?(Google::Protobuf::MessageExts)
            fields(node, path, scopes, *PREDICATES.fetch(node.class, []))
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
        # A SELECT inside an atom starts over: its select list holds no atoms.
        def select(select, path, scopes)
          depth = @depth
          @depth = 0
          walk(select.with_clause, path + ["with_clause"], scopes)
          frame = select.from_clause.flat_map { |item| @frames.rels(item, scopes.size) }
          fields(select, path, scopes + [frame], "where_clause", "having_clause", skip: "with_clause")
        ensure
          @depth = depth
        end

        # A join's ON clause, or each USING column. The join is in the
        # innermost frame, and its ON sees only the join's own inputs there.
        def join(join, path, scopes)
          sides = [join.larg, join.rarg].map { |side| @frames.rels(side, scopes.size - 1) }
          fields(join, path, scopes, skip: "quals")
          predicate(join.quals, path + ["quals"], inputs(scopes, sides)) if join.quals
          join.using_clause.each_with_index { |node, i| add_using(node, sides, path + ["using_clause", i]) }
        end

        # The scopes with the innermost frame cut down to the join's inputs.
        def inputs(scopes, sides) = scopes[0...-1] + [sides.flatten(1)]

        def add_using(node, sides, path)
          name = node.string.sval
          columns = sides.map { |side| @frames.using_column(name, side) }.freeze
          @atoms << Atom.new(kind: :join, operator: "USING", negated: false, bare: true, columns:,
                             shape: "USING (#{Redaction.identifier(name)})", path: path.freeze, replaceable: false)
        end

        # A subquery in FROM sees the FROM it's in only when it's LATERAL.
        # A function always does: Postgres makes it LATERAL.
        def from_subquery(item, path, scopes)
          fields(item, path, item.lateral ? scopes : scopes[0...-1])
        end

        # CASE x WHEN v: each WHEN tests x = v.
        def case_expr(expr, path, scopes)
          return fields(expr, path, scopes) unless expr.arg

          walk(expr.arg, path + ["arg"], scopes)
          expr.args.each_with_index { |node, i| simple_when(expr.arg, node.case_when, path + ["args", i], scopes) }
          walk(expr.defresult, path + ["defresult"], scopes)
        end

        def simple_when(arg, case_when, path, scopes)
          step = path + ["case_when"]
          add_atom(SimpleCase.test(arg, case_when.expr), step + ["expr"], scopes)
          fields(case_when, step, scopes)
        end

        # Splits AND, OR, and NOT. Each other expression is an atom, unless
        # it's a bare constant. An atom can hold more atoms, in a subquery
        # or a CASE.
        def predicate(node, path, scopes)
          bool = node.bool_expr
          if bool
            bool.args.each_with_index { |arg, i| predicate(arg, path + ["bool_expr", "args", i], scopes) }
          else
            add_atom(node, path, scopes) unless constant?(node)
            inside_atom { fields(node, path, scopes) }
          end
        end

        # Inside an atom, each boolean test is a predicate too, such as the
        # x = 1 in coalesce(x = 1, false), (x = 1) IS NOT FALSE, or a CASE
        # result. So is anything in a subquery's WHERE, as everywhere.
        def inside_atom
          @depth += 1
          yield
        ensure
          @depth -= 1
        end

        def constant?(node) = !(node.a_const || node.type_cast&.arg&.a_const).nil?

        def add_atom(node, path, scopes)
          resolved = ColumnRefs.in(node).filter_map { |ref| Resolver.resolve(ref, scopes) }
          test = Test.of(node)
          kind = kind(test, resolved.filter_map(&:first))
          @atoms << Atom.new(kind:, operator: test.operator, negated: kind != :other && test.negated,
                             bare: test.bare?, columns: columns(resolved), shape: @redaction.shape(node),
                             path: path.freeze, replaceable: true)
        end

        def columns(resolved)
          resolved.map { |rel, name| Column.new(table: rel&.table, refname: rel&.refname, name:) }.uniq.freeze
        end

        def kind(test, rels)
          return :join if rels.uniq.size >= 2

          test.family
        end
      end

      # Resolves a ColumnRef to [Rel, name] in a stack of FROM frames,
      # innermost last. The Rel is nil when it can't be placed.
      module Resolver
        module_function

        def resolve(ref, scopes)
          return nil if ref.fields.any?(&:a_star)

          *qualifier, name = ref.fields.map { |f| f.string.sval }
          rel = qualifier.empty? ? unqualified(name, scopes) : qualified(qualifier, scopes)
          [rel, name]
        end

        # The one relation in the innermost frame that has it. A frame with
        # a relation whose columns aren't known stops the search, since
        # that relation might be the one.
        def unqualified(name, scopes)
          scopes.reverse_each do |frame|
            found = frame.select { |rel| rel.columns&.include?(name) }
            return found.first if found.one?
            return nil unless open?(frame, found)
          end
          nil
        end

        # Nothing here has it, and nothing here might.
        def open?(frame, found) = found.empty? && frame.none? { |rel| rel.columns.nil? }

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
          return Tree.children(node).flat_map { |child| self.in(child) } unless node.is_a?(PgQuery::Node)
          return [node.column_ref] if node.column_ref
          return self.in(node.sub_link.testexpr) if node.sub_link

          self.in(node.inner)
        end

        # No column and no subquery.
        def free?(node) = self.in(node).empty? && !subquery?(node)

        def subquery?(node)
          return true if node.is_a?(PgQuery::Node) && node.sub_link

          Tree.children(node).any? { |child| subquery?(child) }
        end
      end

      # What one atom tests, from its syntax: its operator family, its
      # operator, whether the operator negates, the sides that should hold
      # columns, and the sides that should be constant.
      Test = Data.define(:family, :operator, :negated, :operands, :constants) do
        def self.of(node) = Syntax.test(node)

        # Each side that has a column is a plain column.
        # A row's side counts element by element.
        def bare?
          sides = (operands + constants).flat_map { |side| side.row_expr ? side.row_expr.args.to_a : [side] }
          sides = sides.reject { |side| ColumnRefs.free?(side) }
          sides.any? && sides.all?(&:column_ref)
        end
      end

      # Reads an atom's syntax into a Test.
      module Syntax
        module_function

        RANGE = %w[< <= > >=].freeze
        COMPARISONS = (%w[= <>] + RANGE).freeze
        SUBQUERY_TESTS = %i[EXISTS_SUBLINK ANY_SUBLINK ALL_SUBLINK].freeze
        LIKE = { "~~" => "LIKE", "!~~" => "NOT LIKE", "~~*" => "ILIKE", "!~~*" => "NOT ILIKE" }.freeze
        BOOLEAN_TESTS = { IS_TRUE: "IS TRUE", IS_NOT_TRUE: "IS NOT TRUE", IS_FALSE: "IS FALSE",
                          IS_NOT_FALSE: "IS NOT FALSE", IS_UNKNOWN: "IS UNKNOWN",
                          IS_NOT_UNKNOWN: "IS NOT UNKNOWN" }.freeze
        # How to read each kind of A_Expr. Any other kind is other.
        EXPRESSIONS = {
          AEXPR_OP: :operator, AEXPR_DISTINCT: :distinct, AEXPR_NOT_DISTINCT: :distinct,
          AEXPR_LIKE: :like, AEXPR_ILIKE: :like, AEXPR_IN: :in_list,
          AEXPR_OP_ANY: :quantified, AEXPR_OP_ALL: :quantified, AEXPR_BETWEEN: :between,
          AEXPR_NOT_BETWEEN: :between, AEXPR_BETWEEN_SYM: :between, AEXPR_NOT_BETWEEN_SYM: :between
        }.freeze

        # Whether the node is a boolean test: AND, OR, NOT, a comparison,
        # LIKE, IN, BETWEEN, IS NULL, IS TRUE, or a subquery test.
        def boolean?(node)
          return false unless node.is_a?(PgQuery::Node)
          return true if node.bool_expr || node.null_test || node.boolean_test
          return SUBQUERY_TESTS.include?(node.sub_link.sub_link_type) if node.sub_link

          !node.a_expr.nil? && boolean_expression?(node.a_expr)
        end

        def boolean_expression?(expr)
          EXPRESSIONS.key?(expr.kind) && (expr.kind != :AEXPR_OP || COMPARISONS.include?(opname(expr)))
        end

        def opname(expr) = expr.name.map { |n| n.string.sval }.join(".")

        def test(node)
          if node.a_expr then expression(node.a_expr)
          elsif node.null_test then null_test(node.null_test)
          elsif node.boolean_test then other(BOOLEAN_TESTS.fetch(node.boolean_test.booltesttype),
                                             [node])
          else other(nil, [node])
          end
        end

        def other(operator, operands) = Test.new(family: :other, operator:, negated: false, operands:, constants: [])

        def null_test(test)
          negated = test.nulltesttype == :IS_NOT_NULL
          checked(:null_test, negated ? "IS NOT NULL" : "IS NULL", negated, [test.arg], [])
        end

        def expression(expr)
          opname = opname(expr)
          reader = EXPRESSIONS[expr.kind]
          reader ? send(reader, opname, expr) : other(opname, [expr.lexpr, expr.rexpr].compact)
        end

        def operator(opname, expr)
          if expr.lexpr.row_expr && expr.rexpr.row_expr then symmetric(:row_comparison, opname, opname == "<>", expr)
          elsif opname == "=" then symmetric(:equality, opname, false, expr)
          elsif opname == "<>" then symmetric(:equality, opname, true, expr)
          elsif RANGE.include?(opname) then symmetric(:range, opname, false, expr)
          else other(opname, [expr.lexpr, expr.rexpr])
          end
        end

        def distinct(_opname, expr)
          negated = expr.kind == :AEXPR_DISTINCT
          symmetric(:equality, negated ? "IS DISTINCT FROM" : "IS NOT DISTINCT FROM", negated, expr)
        end

        def like(opname, expr) = one_sided(:like, LIKE.fetch(opname), opname.start_with?("!"), expr)

        def in_list(opname, expr)
          negated = opname == "<>"
          checked(:in, negated ? "NOT IN" : "IN", negated, [expr.lexpr], expr.rexpr.list.items.to_a)
        end

        # = ANY and <> ALL test a list. Others don't.
        def quantified(opname, expr)
          any = expr.kind == :AEXPR_OP_ANY
          operator = "#{opname} #{any ? "ANY" : "ALL"}"
          return other(operator, [expr.lexpr, expr.rexpr]) unless opname == (any ? "=" : "<>")

          one_sided(:in, operator, !any, expr)
        end

        def between(opname, expr)
          checked(:range, opname, opname.start_with?("NOT"), [expr.lexpr], expr.rexpr.list.items.to_a)
        end

        def one_sided(family, operator, negated, expr) = checked(family, operator, negated, [expr.lexpr], [expr.rexpr])

        # The column may be on either side.
        def symmetric(family, operator, negated, expr)
          left = expr.lexpr
          right = expr.rexpr
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

      private_constant :Tree, :SimpleCase, :Literals, :Redaction, :Rel, :Frames, :Walker, :Resolver, :ColumnRefs,
                       :Test, :Syntax
    end
  end
end
