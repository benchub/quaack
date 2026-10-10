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

      def with_params(text)
        marks = PgQuery.scan(text).first.tokens.select { text.byteslice(it.start...it.end) == "?" }
        bytes = text.b
        marks.reverse_each { |token| bytes[token.start...token.end] = "$1".b }
        bytes.force_encoding(text.encoding)
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
