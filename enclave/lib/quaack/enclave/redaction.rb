# frozen_string_literal: true

require_relative "deparse"

module Quaack
  module Enclave
    # README 3g: the redacted query and plans, which are what the driver
    # and every LLM call get, and the placeholder map, which stays in the
    # governed store.
    #
    #   Redaction.query(qualified.parse)
    #   # => RedactedQuery(sql: "SELECT ... WHERE o.status = $1 ...", placeholders: [Placeholder, ...])
    #
    # Query redaction replaces each constant in the query's parse (every
    # A_Const, cast or not, NULL included) with $n, numbered in the order
    # the constants appear in the text, and deparses the result with
    # Deparse.faithfully, so a query pg_query would deparse as something
    # else is refused with Deparse::Error. The parse should be the
    # qualified query's (RelationQualifier's parse). These constants stay
    # as written, since they aren't values:
    # - One the parser made, which has no location, such as the 1 of FETCH
    #   FIRST ROWS ONLY (the rule 20260923-29 set).
    # - A cast's type and its modifiers, such as the 12 of varchar(12),
    #   which are shape (see 20260923-30). The cast itself stays too, so
    #   DATE '2031-07-19' becomes $1::date.
    # - EXTRACT's field, when it's one Postgres documents.
    # - A bare constant in ORDER BY, GROUP BY, or DISTINCT ON, which names
    #   an output column by position. A $n there would mean a constant.
    #
    # The query must pass SupportedSql, and must not have $n parameters of
    # its own, which would clash with the placeholders (Error
    # query_has_parameters). Intake refuses those already.
    #
    # Trust boundary: RedactedQuery#sql and #placeholder_shapes are
    # shape-class. #placeholder_map holds the literals, so it's value-class
    # and stays in the store. inspect shows neither the map nor any
    # Placeholder's value.
    module Redaction
      # Its message is the rule, and never quotes the query.
      class Error < StandardError
        def rule = message
      end

      # One placeholder. value is the literal as text, or nil for NULL.
      # type is the literal's type for PREPARE (see Literal.of). shape is
      # its shape annotation: "type", the type class (text, integer,
      # numeric, boolean, datetime, or other, from the constant or its
      # cast), "pattern" for a LIKE or ILIKE pattern (leading_wildcard,
      # trailing_wildcard, both_wildcards, or no_wildcard), and "elements"
      # for a member of an IN list or ARRAY[...], or an array literal: the
      # list's length, or the literal's.
      Placeholder = Data.define(:number, :value, :type, :shape) do
        def inspect = "#<data #{self.class} number=#{number}, type=#{type}, shape=#{shape}, value=<redacted>>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      RedactedQuery = Data.define(:sql, :placeholders) do
        # $n => {"value", "type"}: value-class, for the governed store only.
        def placeholder_map = placeholders.to_h { |p| ["$#{p.number}", { "value" => p.value, "type" => p.type }] }

        # $n => shape: shape-class.
        def placeholder_shapes = placeholders.to_h { |p| ["$#{p.number}", p.shape] }

        def inspect = "#<data #{self.class} sql=#{sql.inspect}, placeholders=#{placeholders.inspect}>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      module_function

      def query(parse)
        redacted = Query.new(parse)
        sql = Deparse.faithfully(redacted.tree)
        RedactedQuery.new(sql:, placeholders: redacted.placeholders)
      end
    end
  end
end

require_relative "redaction/query"
