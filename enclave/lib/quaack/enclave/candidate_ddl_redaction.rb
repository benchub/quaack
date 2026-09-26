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
    # constant in the DDL is masked as ? unless its text is one of the MCV
    # values the classification lets out for a column of the candidate's own
    # table: the low-cardinality values of README 3f, which the payload's
    # stats already carry. NULL has no value and stays.
    #
    # outbound_statistics is the classification entry's, as
    # PiiClassification stores it.
    class CandidateDdlRedaction
      def initialize(outbound_statistics)
        @allowed = outbound_statistics.fetch("tables").to_h do |table|
          values = table["columns"].flat_map { it["most_common_vals"] || [] }
          [[table["schema"], table["name"]], values.to_set]
        end
      end

      def ddl(candidate)
        allowed = @allowed.fetch([candidate.table.schema, candidate.table.name], Set.new)
        parse = PgQuery.parse(candidate.to_ddl)
        NodeRewrite.each(parse.tree) { |node| mask(node, allowed) }
        PgQuery.deparse(parse.tree)
      end

      private

      # A ? for a constant whose text isn't allowed, and nil (walk on) for
      # every other node.
      def mask(node, allowed)
        return unless node.node == :a_const

        text = text(node.a_const)
        return if text.nil? ? node.a_const.isnull : allowed.include?(text)

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
