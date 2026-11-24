# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The shape of a DDL string, for the run's internal_errors.log when its
    # candidate is withheld (20261124-233000-1): the kinds of its parse
    # nodes, nested in parentheses, and nothing else. Every identifier,
    # constant, collation, operator, and other string or number in the tree
    # is left out, since only the message types' names are written.
    #
    #   DdlFingerprint.of("CREATE INDEX ON s.t (a) WHERE b = 1")
    #   # => "IndexStmt(RangeVar,IndexElem,AExpr(String,ColumnRef(String),AConst(Integer)))"
    module DdlFingerprint
      SHAPE = /\A[A-Za-z(),]{1,4000}\z/
      MAX_NODES = 400

      # CandidateDdlRedaction's fail-closed #outbound_ddl, for one candidate.
      module Withholding
        # The shapes of the candidates #withholding_ddl withheld, in order.
        def withheld = (@withheld ||= [])

        # #outbound_ddl, or nil, with the candidate's shape added to
        # withheld, where #outbound_ddl would raise, so a caller drops that
        # candidate and carries on. Its DDL never goes anywhere.
        def withholding_ddl(candidate)
          outbound_ddl(candidate)
        rescue self.class::Error
          withheld << DdlFingerprint.of(candidate.to_ddl)
          nil
        end
      end

      module_function

      # The shape, or "unparsable" for text pg_query can't parse.
      def of(text)
        tree = PgQuery.parse(text).tree
        budget = [MAX_NODES]
        tree.stmts.map { shape(it.stmt, budget) }.join(",")
      rescue PgQuery::ParseError, ArgumentError, TypeError
        "unparsable"
      end

      def shape(message, budget)
        message = unwrap(message) or return ""
        budget[0] -= 1
        name = message.class.name.split("::").last.delete("_")
        return name if budget[0].negative?

        children = children(message).map { shape(it, budget) }.reject(&:empty?)
        children.empty? ? name : "#{name}(#{children.join(",")})"
      end

      def unwrap(message) = message.is_a?(PgQuery::Node) ? message.public_send(message.node) : message

      def children(message) = message.class.descriptor.flat_map { field_children(message, it) }

      def field_children(message, field)
        return [] unless field.type == :message

        value = message[field.name]
        value.respond_to?(:to_a) && field.label == :repeated ? value.to_a : [value].compact
      end
    end
  end
end
