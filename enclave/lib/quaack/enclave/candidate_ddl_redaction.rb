# frozen_string_literal: true

require "pg_query"
require_relative "node_rewrite"
require_relative "pg_array"
require_relative "redacted_ddl_text"
require_relative "table_name"

module Quaack
  module Enclave
    # A stored index candidate's DDL, made fit to leave the enclave for the
    # llm-index-ideas payload (DESIGN.md's index-dedupe, llm-index-ideas, and the 20260925-4 note).
    #
    #   CandidateDdlRedaction.new(outbound_statistics).ddl(candidate)
    #   # => "CREATE INDEX ON public.orders USING btree (created_at) WHERE status = 'held' AND note = ?"
    #
    # Generator two reads the unredacted input plan, so a candidate's
    # partial predicate or key expression can hold a real literal. Every
    # constant in the DDL is masked as ? unless it's in the predicate,
    # compared directly (col = const, const <> col, col IN (...), col = ANY
    # (ARRAY[...]), col = ANY ('{...}') with every element allowed, casts
    # allowed) with a low-cardinality column of the candidate's table, and
    # its text is one of that column's MCV values: the values DESIGN.md's classify
    # lets out, which the payload's stats already carry. Key expressions
    # and function arguments are masked whole. NULL has no value and stays.
    #
    # outbound_statistics is the classification entry's, as
    # PiiClassification stores it.
    class CandidateDdlRedaction
      # A DDL string that isn't in redacted form was about to leave (20261009-58).
      class Error < StandardError; end

      def initialize(outbound_statistics)
        @allowed = outbound_statistics.fetch("tables").to_h do |table|
          columns = table["columns"].select { it["most_common_vals"] }
          [[table["schema"], table["name"]], columns.to_h { [it["name"], it["most_common_vals"].to_set] }]
        end
      end

      def ddl(candidate)
        parse = PgQuery.parse(candidate.to_ddl)
        redact!(parse.tree.stmts.first.stmt.index_stmt, allowed(candidate.table))
        PgQuery.deparse(parse.tree)
      end

      # #ddl, checked on the way out: the string #ddl made, if redacted? says
      # it is redacted, and an Error with a fixed message, naming none of
      # it, if not. Every DDL string a payload or report carries comes
      # through here (or redacted? itself, for NegativeResult).
      def outbound_ddl(candidate)
        ddl(candidate).tap { raise Error, "a DDL string isn't in redacted form" unless redacted?(it) }
      end

      # Whether text, a DDL string as #ddl made it (its masks written ?),
      # is already redacted: one CREATE INDEX that redacting again, with
      # the same rules, over the table it names, changes nothing but the
      # masks' spelling. A literal #ddl would have masked, or a statement
      # of any other shape, is false. This is the check on the way out, so
      # it never trusts how the string was made. Never raises.
      def redacted?(text)
        once = RedactedDdlText.parse(text)
        return false unless once

        twice = RedactedDdlText.parse(text)
        stmt = twice.tree.stmts.first.stmt.index_stmt
        redact!(stmt, allowed(TableName.new(schema: stmt.relation.schemaname, name: stmt.relation.relname)))
        RedactedDdlText.spelled(once) == RedactedDdlText.spelled(twice)
      rescue PgQuery::ParseError, ArgumentError
        false
      end

      def redact!(stmt, allowed)
        mask_all(stmt.index_params)
        stmt.where_clause = predicate(stmt.where_clause, allowed)
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
        column, constants, array_text = operands(node)
        values = allowed[column]
        return unless values

        constants.each { |c| masked!(c) unless c.node == :param_ref || allowed_constant?(c, values, array_text) }
        node
      end

      # An ANY's constant is an array literal such as '{held,open}', kept
      # only if every element is one of the column's values.
      def allowed_constant?(constant, values, array_text)
        return values.include?(text(constant.a_const)) unless array_text

        elements = PgArray.parse(text(constant.a_const).to_s)
        elements.all? { |e| e.nil? || values.include?(e) }
      rescue ArgumentError
        false
      end

      # sides of an operator or IN expression, either way round, or of
      # col = ANY (ARRAY[...]) and col = ANY ('{...}'), column first.
      def operands(node)
        return unless node.node == :a_expr

        expr = node.a_expr
        return any_operands(expr) if expr.kind == :AEXPR_OP_ANY
        return unless %i[AEXPR_OP AEXPR_IN].include?(expr.kind)

        sides(expr.lexpr, expr.rexpr) || sides(expr.rexpr, expr.lexpr)
      end

      def any_operands(expr)
        array = uncast(expr.rexpr)
        unless array&.node == :a_array_expr
          found = sides(expr.lexpr, expr.rexpr)
          return found && [*found, true]
        end

        items = array.a_array_expr.elements.to_a
        name = column_name(uncast(expr.lexpr))
        constants = items.map { const_node(it) }
        [name, constants] if name && constants.all?
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
        node if %i[a_const param_ref].include?(node&.node)
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
