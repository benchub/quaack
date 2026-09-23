# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # Parses the expression strings in an EXPLAIN plan (Filter, Index Cond,
    # Recheck Cond, Join Filter, Hash Cond, Sort Key, and Group Key) with
    # pg_query, for GeneratorTwo. It's private to the enclave namespace.
    #
    # The strings hold real literals. Nothing here raises on them: a string
    # that doesn't parse as what it should gives back nothing, so no error
    # can quote it.
    module PlanExpression
      module_function

      # The top-level AND conjuncts of a condition, as parse tree nodes, or
      # [] if it doesn't parse. Postgres prints some conditions pg_query
      # can't read, such as "(id = (InitPlan 1).col1)", so those give [].
      # So does nil, for a node without the condition.
      def conjuncts(text)
        where = parse_select("SELECT WHERE #{text}")&.where_clause
        return [] unless where

        where.node == :bool_expr && where.bool_expr.boolop == :AND_EXPR ? where.bool_expr.args.to_a : [where]
      end

      # One Sort Key or Group Key, as [expression node, direction, nulls], or
      # nil if it doesn't parse or uses USING. direction is :asc or :desc.
      # nulls is :first, :last, or nil for the direction's default.
      def sort_key(text)
        select = parse_select("SELECT ORDER BY #{text}")
        sort_by = select.sort_clause.first&.sort_by if select
        return nil if sort_by.nil? || sort_by.sortby_dir == :SORTBY_USING

        [sort_by.node, sort_by.sortby_dir == :SORTBY_DESC ? :desc : :asc,
         { SORTBY_NULLS_FIRST: :first, SORTBY_NULLS_LAST: :last }[sort_by.sortby_nulls]]
      end

      # Parses SQL that must be one SELECT with nothing but a WHERE clause or
      # a one-key ORDER BY. Anything else, including a string that closes the
      # clause and adds more, gives nil.
      def parse_select(sql)
        stmts = PgQuery.parse(sql).tree.stmts
        select = stmts.first.stmt.select_stmt if stmts.size == 1
        select if select && bare?(select)
      rescue PgQuery::ParseError
        nil
      end

      def bare?(select)
        only = PgQuery::SelectStmt.new(where_clause: select.where_clause, sort_clause: select.sort_clause.to_a,
                                       limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
        select == only && [select.where_clause, select.sort_clause.size == 1].one?
      end

      # The column a node refers to, as its name parts, such as ["o", "id"]:
      # a ColumnRef, or a ColumnRef under casts, as Postgres prints
      # "(status)::text". Otherwise nil.
      def column_parts(node)
        node = uncast(node)
        return nil unless node.node == :column_ref

        # A * gives a nil part, which never matches a column name.
        node.column_ref.fields.map { |f| f.string&.sval }
      end

      # A constant: a literal, a parameter, or either under casts.
      def constant?(node) = %i[a_const param_ref].include?(uncast(node).node)

      # The literal in an `a = literal` conjunct, as text, the way pg_stats
      # would print it, or nil if there's no literal. The text is a real
      # value: pass it to TableStatistics#value_frequency and nowhere else.
      def literal_text(node)
        constant = equality_sides(node)&.map { |side| uncast(side) }&.find { |side| side.node == :a_const }
        value = constant&.a_const
        case value&.val
        when :sval then value.sval.sval
        when :ival then value.ival.ival.to_s
        when :fval then value.fval.fval
        when :boolval then value.boolval.boolval.to_s
        end
      end

      def uncast(node)
        node = node.type_cast.arg while node.node == :type_cast
        node
      end

      # The two sides of an `a = b` conjunct, or nil for anything else.
      def equality_sides(node)
        expr = node.a_expr if node.node == :a_expr
        return nil unless expr&.kind == :AEXPR_OP && expr.name.map { |n| n.string.sval } == ["="]

        [expr.lexpr, expr.rexpr]
      end

      # The name parts of every column under node, in the order they appear.
      def column_refs(node)
        found = []
        each_message(node) { |m| found << m.fields.map { |f| f.string&.sval } if m.is_a?(PgQuery::ColumnRef) }
        found
      end

      def each_message(message, &)
        yield message
        message.class.descriptor.each do |field|
          next unless field.type == :message

          value = message[field.name]
          (field.label == :repeated ? value.to_a : [value].compact).each { |m| each_message(m, &) }
        end
      end

      # The conjunct as SQL, with every column's qualifier dropped, for a
      # partial index predicate. It holds the conjunct's literal.
      def unqualified_sql(node)
        copy = PgQuery::Node.decode(PgQuery::Node.encode(node))
        each_message(copy) do |m|
          m.fields.replace([m.fields.last]) if m.is_a?(PgQuery::ColumnRef)
        end
        PgQuery.deparse_expr(copy)
      end
    end

    private_constant :PlanExpression
  end
end
