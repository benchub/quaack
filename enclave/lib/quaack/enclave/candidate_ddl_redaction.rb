# frozen_string_literal: true

require "pg_query"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # A stored index candidate's DDL, made fit to leave the enclave for the
    # 5a-5 payload (README 5a-3, 5a-5, and the 20260925-4 note).
    #
    #   CandidateDdlRedaction.new(outbound_statistics).ddl(candidate)
    #   # => "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'held' AND note = ?"
    #
    # Generator two reads the unredacted step 1 plan, so a candidate's
    # partial predicate or key expression can hold a real literal. Every
    # constant in the DDL is masked as ? unless it's in the predicate,
    # compared directly (col = const, const <> col, col IN (...), casts
    # allowed) with a low-cardinality column of the candidate's table, and
    # its text is one of that column's MCV values: the values README 3f
    # lets out, which the payload's stats already carry. Key expressions
    # and function arguments are masked whole. NULL has no value and stays.
    #
    # outbound_statistics is the classification entry's, as
    # PiiClassification stores it.
    class CandidateDdlRedaction
      def initialize(outbound_statistics)
        @allowed = outbound_statistics.fetch("tables").to_h do |table|
          columns = table["columns"].select { it["most_common_vals"] }
          [[table["schema"], table["name"]], columns.to_h { [it["name"], it["most_common_vals"].to_set] }]
        end
      end

      def ddl(candidate)
        parse = PgQuery.parse(candidate.to_ddl)
        stmt = parse.tree.stmts.first.stmt.index_stmt
        mask_all(stmt.index_params)
        stmt.where_clause = predicate(stmt.where_clause, allowed(candidate.table))
        PgQuery.deparse(parse.tree)
      end

      def allowed(table) = @allowed.fetch([table.schema, table.name], {})

      def mask_all(params) = params.each { |param| NodeRewrite.each(param) { mask(it) } }

      # The predicate, with only its comparisons' allowed values kept.
      def predicate(where_clause, allowed)
        holder = PgQuery::SelectStmt.new(where_clause:)
        NodeRewrite.each(holder) { |node| comparison(node, allowed) || mask(node) }
        holder.where_clause
      end

      private

      # For col = const, const <> col, or col IN (consts), with col one of
      # the low-cardinality columns (either side may be cast): masks each
      # constant that isn't one of col's values, and returns the node so
      # its children aren't walked again. nil for any other node. Only the
      # predicate has such comparisons: a key expression is masked whole.
      def comparison(node, allowed)
        column, constants = operands(node)
        values = allowed[column]
        return unless values

        constants.each { |c| masked!(c) unless values.include?(text(c.a_const)) }
        node
      end

      # sides of an operator or IN expression, either way round.
      def operands(node)
        return unless node.node == :a_expr && %i[AEXPR_OP AEXPR_IN].include?(node.a_expr.kind)

        expr = node.a_expr
        sides(expr.lexpr, expr.rexpr) || sides(expr.rexpr, expr.lexpr)
      end

      # [column name, the A_Const nodes] when column is a plain column
      # reference and other is constants, each maybe cast.
      def sides(column, other)
        name = column_name(uncast(column))
        return unless name

        items = other&.node == :list ? other.list.items.to_a : [other]
        constants = items.map { const_node(it) }
        [name, constants] if constants.all?
      end

      def column_name(node)
        field = node.column_ref.fields.last if node&.node == :column_ref
        field.string.sval if field&.node == :string
      end

      def uncast(node) = node&.node == :type_cast ? node.type_cast.arg : node

      def const_node(node)
        node = uncast(node)
        node if node&.node == :a_const
      end

      def masked!(node) = node.param_ref = PgQuery::ParamRef.new(number: 0)

      # Every constant outside such a comparison is masked, but NULL.
      def mask(node)
        return unless node.node == :a_const && !node.a_const.isnull

        PgQuery::Node.new(param_ref: PgQuery::ParamRef.new(number: 0))
      end

      def text(constant)
        case constant.val
        when :sval then constant.sval.sval
        when :ival then constant.ival.ival.to_s
        when :fval then constant.fval.fval
        when :boolval then constant.boolval.boolval ? "t" : "f"
        when :bsval then constant.bsval.bsval
        end
      end
    end
  end
end
