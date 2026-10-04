# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "arena_schema"
require_relative "predicate_atoms"

module Quaack
  module Enclave
    # Step 9: each atom's pool of interesting values.
    #
    #   pools = ValuePools.build(arena_connection, parse, atoms, schema)
    #   pools[2]  # => Pool for atoms[2], or no key when it has no pool
    #
    # An atom gets a pool when it's an equality, range, LIKE, IN, or IS NULL
    # test on exactly one column of a plain table. Joins and :other atoms
    # don't. The candidates are, in this order: the literal values (each
    # side of the test that names no column, cast to the column's type),
    # one unit on either side of each, case variants for text, a matching
    # and a non-matching value for a LIKE pattern, NULL for a nullable
    # column, and the type's boundary values and typical value. Postgres
    # sorts them: each candidate is bound in place of the column and the
    # atom is evaluated, so collations, casts, and expressions on the column
    # (lower(name) = 'bob') come out right. satisfying holds the ones that
    # make the atom true, failing the ones that make it false, in candidate
    # order. A candidate that makes it NULL is in neither. A candidate the
    # column's type can't read is dropped.
    #
    # The connection is arena's, outside any transaction. Nothing is
    # written. Trust boundary: pools hold real values, so they stay in the
    # enclave. inspect leaves the values out.
    module ValuePools
      KINDS = %i[equality range like in null_test].freeze

      Pool = Data.define(:column, :type, :oid, :nullable, :satisfying, :failing, :boundaries) do
        def inspect = "#<data #{self.class} column=#{column.name} values=<redacted>>"

        alias_method :to_s, :inspect
      end

      # Type boundary values, by the type's name as format_type gives it.
      BOUNDARIES = {
        /\Asmallint/ => %w[-32768 32767 0],
        /\Ainteger/ => %w[-2147483648 2147483647 0],
        /\Abigint/ => %w[-9223372036854775808 9223372036854775807 0],
        /\Anumeric/ => %w[0 -99999999999999 99999999999999 0.000001],
        /\A(real|double)/ => %w[0 -Infinity Infinity NaN],
        /\Adate/ => ["-infinity", "infinity", "1970-01-01"],
        /\Atimestamp/ => ["-infinity", "infinity", "1970-01-01 00:00:00+00"],
        /\A(text|character|"char"|citext)/ => ["", "~"],
        /\Aboolean/ => %w[f t],
        /\Auuid/ => %w[00000000-0000-0000-0000-000000000000 ffffffff-ffff-ffff-ffff-ffffffffffff]
      }.freeze

      # One unit, by type category (pg_type.typcategory).
      STEPS = { "N" => ["1"], "D" => ["1", "interval '1 second'", "interval '1 day'"] }.freeze

      module_function

      # probes, by atom index, are the probes to sort with (see probes).
      def build(conn, parse, atoms, schema, probes = {})
        atoms.each_with_index.filter_map do |atom, i|
          next unless pooled?(atom)

          [i, pool(conn, parse, atom, schema, probes[i])]
        end.to_h
      end

      # Each pooled atom's probe, by index, asking Postgres once per value
      # (CachedProbe).
      def probes(conn, parse, atoms, schema)
        atoms.each_with_index.filter_map do |atom, i|
          next unless pooled?(atom)

          column = atom.columns[0]
          [i, CachedProbe.new(probe(conn, parse, atom, schema.column(column.table, column.name)))]
        end.to_h
      end

      # The row comparison operators whose leading column can decide them.
      ROW_RANGE = %w[< <= > >=].freeze

      # A keyset row comparison with a range operator is pooled through its
      # leading column, when every element of its column row is a plain
      # column of a table.
      def pooled?(atom)
        return atom.columns.size == 1 && !atom.columns[0].table.nil? if KINDS.include?(atom.kind)

        atom.kind == :row_comparison && ROW_RANGE.include?(atom.operator) && atom.bare && atom.columns.all?(&:table)
      end

      # The probe for a pooled atom (see Probe).
      def probe(conn, parse, atom, col) = Probe.new(conn, node(parse, atom), col)

      # The test the atom's pool and probe read: the atom's own node, or
      # for a row comparison, its leading elements' comparison with the tie
      # made NULL. (a, b) <= (x, y) reads NULLIF(a, x) <= x: true when
      # a < x, false when a > x, and NULL when a = x, where b decides.
      def node(parse, atom)
        node = PredicateAtoms.node(parse, atom)
        atom.kind == :row_comparison ? lead(node.a_expr) : node
      end

      def lead(expr)
        lexpr, rexpr = [expr.lexpr, expr.rexpr].map { |side| side.row_expr.args[0] }
        lexpr.column_ref ? lexpr = nullif(lexpr, rexpr) : rexpr = nullif(rexpr, lexpr)
        a_expr(:AEXPR_OP, expr.name.to_a, lexpr, rexpr)
      end

      def nullif(column, value)
        a_expr(:AEXPR_NULLIF, [PgQuery::Node.new(string: PgQuery::String.new(sval: "="))],
               column, value)
      end

      def a_expr(kind, name, lexpr, rexpr)
        PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind:, name:, lexpr:, rexpr:))
      end

      # An array type, such as bigint[], has none.
      def boundaries(type)
        return [] if type.end_with?("]")

        BOUNDARIES.find { |pattern, _| pattern.match?(type) }&.last || []
      end

      def pool(conn, parse, atom, schema, probe = nil)
        column = atom.columns[0]
        col = schema.column(column.table, column.name)
        node = node(parse, atom)
        sorted(conn, node, col, probe || Probe.new(conn, node, col)) => { satisfying:, failing:, boundaries: }
        Pool.new(column:, type: col.type, oid: col.oid, nullable: col.nullable, satisfying:, failing:, boundaries:)
      end

      def sorted(conn, node, col, probe = Probe.new(conn, node, col))
        groups = candidates(conn, node, col).uniq.group_by { |v| probe.call(v) }
        { satisfying: groups.fetch("t", []), failing: groups.fetch("f", []),
          boundaries: boundaries(col.type).select { |v| probe.readable?(v) } }
      end

      def candidates(conn, node, col)
        literals = Sides.literals(conn, node, col)
        category = conn.exec_params("SELECT typcategory FROM pg_type WHERE oid = $1", [col.oid]).getvalue(0, 0)
        near = literals.flat_map { |v| steps(conn, v, col, category) }
        literals + near + variants(node, literals, category) + (col.nullable ? [nil] : []) + boundaries(col.type)
      end

      # Case variants for text, and a LIKE pattern's matching and
      # non-matching values.
      def variants(node, literals, category)
        text = category == "S" ? literals.flat_map { |v| [v.upcase, v.downcase, v.capitalize] } : []
        like = node.a_expr && %i[AEXPR_LIKE AEXPR_ILIKE].include?(node.a_expr.kind)
        text + (like ? like_values(literals) : [])
      end

      def steps(conn, value, col, category)
        STEPS.fetch(category, []).flat_map do |step|
          %w[+ -].filter_map do |op|
            sql = "SELECT (CAST($1 AS #{col.type}) #{op} #{step})::#{col.type}::text"
            conn.exec_params(sql, [value]).getvalue(0, 0)
          rescue PG::Error
            nil
          end
        end
      end

      # A pattern's plain reading, with % dropped and _ as x, and one that
      # can't match an anchored pattern.
      def like_values(patterns)
        patterns.flat_map do |p|
          plain = p.gsub(/\\(.)|[%_]/) { ::Regexp.last_match(1) || (::Regexp.last_match(0) == "_" ? "x" : "") }
          [plain, plain.swapcase, "\u0001#{plain}\u0001"]
        end
      end

      # Evaluates the atom with a value in place of its column.
      class Probe
        def initialize(conn, node, col)
          @conn = conn
          @col = col
          copy = Sides.copy(node)
          Sides.replace_columns(copy)
          @sql = Sides.select_of(copy)
        end

        # "t", "f", nil for NULL, or :unreadable.
        def call(value)
          @conn.exec_params(@sql, [{ value:, type: @col.oid }]).getvalue(0, 0)
        rescue PG::Error
          :unreadable
        end

        def readable?(value)
          @conn.exec_params("SELECT CAST($1 AS #{@col.type})", [value])
          true
        rescue PG::Error
          false
        end

        # Probes with the same key give the same answers.
        def key = [@sql, @col.oid, @col.type]
      end

      # A Probe that asks Postgres once per value. The answers hold real
      # values, so they stay in the enclave.
      class CachedProbe
        def initialize(probe)
          @probe = probe
          @answers = {}
          @readable = {}
        end

        def call(value) = @answers.fetch(value) { @answers[value] = @probe.call(value) }
        def readable?(value) = @readable.fetch(value) { @readable[value] = @probe.readable?(value) }
      end

      # Tree helpers.
      module Sides
        module_function

        def copy(message)
          message.class.decode(message.class.encode(message, recursion_limit: 1_000), recursion_limit: 1_000)
        end

        def children(node)
          case node
          when Google::Protobuf::RepeatedField then node.to_a
          when Google::Protobuf::MessageExts then node.class.descriptor.map { |field| field.get(node) }
          else []
          end
        end

        def column_ref?(node) = contains?(node) { |n| n.is_a?(PgQuery::Node) && n.column_ref }

        def contains?(node, &block)
          return true if block.call(node)

          Sides.children(node).any? { |c| contains?(c, &block) }
        end

        def param = PgQuery::Node.new(param_ref: PgQuery::ParamRef.new(number: 1))

        def column_node?(value) = value.is_a?(PgQuery::Node) && value.column_ref

        # Puts $1 in place of every column reference under node.
        def replace_columns(node)
          case node
          when Google::Protobuf::RepeatedField
            node.each_with_index { |c, i| column_node?(c) ? node[i] = param : replace_columns(c) }
          when Google::Protobuf::MessageExts
            node.class.descriptor.each do |field|
              value = field.get(node)
              column_node?(value) ? field.set(node, param) : replace_columns(value)
            end
          end
        end

        # A list or an ARRAY[...] gives each element.
        def sides(expr)
          [expr.lexpr, expr.rexpr].compact.flat_map do |s|
            if s.list then s.list.items.to_a
            elsif s.a_array_expr then s.a_array_expr.elements.to_a
            else [s]
            end
          end
        end

        def select_of(expr)
          tree = PgQuery.parse("SELECT 1").tree
          tree.stmts[0].stmt.select_stmt.target_list[0].res_target.val = expr
          PgQuery.deparse(tree)
        end

        # Every side of the test that names no column, evaluated and cast
        # to the column's type.
        def literals(conn, node, col)
          expr = node.a_expr
          return [] unless expr

          sides(expr).reject { |s| column_ref?(s) }.filter_map do |side|
            conn.exec(<<~SQL).getvalue(0, 0)
              SELECT CAST(q.v AS #{col.type})::text FROM (#{select_of(Sides.copy(side))}) q(v)
            SQL
          rescue PG::Error
            nil
          end
        end
      end
    end
  end
end
