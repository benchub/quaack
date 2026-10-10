# frozen_string_literal: true

require "pg_query"
require_relative "node_rewrite"

module Quaack
  module Enclave
    # A DDL string as CandidateDdlRedaction#ddl wrote it, read back into a
    # tree: its masks are written ?, which isn't SQL, so each one the lexer
    # finds (never one inside a string or an identifier) is read as a
    # parameter first.
    #
    #   RedactedDdlText.parse("CREATE INDEX ON public.t USING btree (a) WHERE b = ?")
    #   # => the PgQuery parse of it, or nil unless it's exactly one CREATE INDEX
    #
    # Raises PgQuery::ParseError for text that isn't SQL.
    module RedactedDdlText
      module_function

      def parse(text)
        return unless text.is_a?(String)

        parse = PgQuery.parse(with_params(text))
        parse if parse.tree.stmts.size == 1 && parse.tree.stmts.first.stmt.node == :index_stmt
      end

      # Tokens after which a ? can only be an operator: a name, a constant, or
      # a closing bracket (a mask never directly follows one of those).
      OPERAND_ENDS = %i[IDENT SCONST ICONST FCONST BCONST XCONST USCONST ASCII_41 ASCII_93].freeze # rubocop:disable Naming/VariableNumber
      # Unreserved keywords that expect an operand next, not end one.
      OPERAND_EXPECTING = %i[ESCAPE ZONE].freeze

      # The text with each mask read as $1. A ? that follows an operand is
      # the jsonb key-exists operator (20261009-57), never a mask, and is
      # left as it is; ?| and ?& are their own tokens.
      def with_params(text)
        bytes = text.b
        masks(text).reverse_each { |token| bytes[token.start...token.end] = "$1".b }
        bytes.force_encoding(text.encoding)
      end

      def masks(text)
        after_operand = false
        PgQuery.scan(text).first.tokens.filter_map do |token|
          mark = text.byteslice(token.start...token.end) == "?"
          operator = mark && after_operand
          after_operand = mark ? !operator : operand_end?(token)
          token if mark && !operator
        end
      end

      def operand_end?(token)
        OPERAND_ENDS.include?(token.token) ||
          (token.keyword_kind == :UNRESERVED_KEYWORD && !OPERAND_EXPECTING.include?(token.token))
      end

      # The tree as text, every mask and parameter spelled the same.
      def spelled(parse)
        NodeRewrite.each(parse.tree) do |node|
          node.param_ref.number = 0 if node.node == :param_ref
          nil
        end
        PgQuery.deparse(parse.tree)
      end
    end
  end
end
