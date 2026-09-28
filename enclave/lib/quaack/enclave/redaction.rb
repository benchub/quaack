# frozen_string_literal: true

require_relative "deparse"

module Quaack
  module Enclave
    # DESIGN.md 3g: the redacted query and plans, which are what the driver
    # and every LLM call get, and the placeholder map, which stays in the
    # governed store.
    #
    #   result = Redaction.redact(qualified.parse, explain)   # the step 1 plan
    #   result.query.sql            # "SELECT ... WHERE o.status = $1 ..."
    #   result.plan.explain         # the plan, with $n where its literals were
    #   result.placeholder_shapes   # {"$1" => {"type" => "text", "rows" => {...}}}
    #   result.store(store)         # the placeholder_map and placeholder_shapes entries
    #
    #   Redaction.plan(racetrack_explain, Redaction.placeholder_map(store))
    #   bound = Redaction.binding(candidate_sql, Redaction.placeholder_map(store))
    #   bound.prepare(connection, "quaack_q")
    #   bound.execute(connection, "quaack_q")
    #
    # == The query
    #
    # Redaction.query replaces each constant in the query's parse (every
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
    # query_has_parameters). Intake refuses those already. An interval
    # constant with a field qualifier, such as INTERVAL '1' DAY, is refused
    # too (Error interval_field_qualifier): the qualifier changes how the
    # literal reads, and a bound parameter can't carry it.
    #
    # == Plans
    #
    # Redaction.plan builds a new plan from a whitelist of EXPLAIN's fields
    # (see Plan), with each literal in an expression replaced with the
    # placeholder whose value it matches, after its cast is set aside
    # (see Matcher), or with $? when none does. The same map redacts the
    # step 1 plan and every racetrack plan. masked counts the $? masks, for
    # the 15b burndown. dropped counts known fields left out because they
    # couldn't be read.
    #
    # == Expressions that must match
    #
    # Each constant gets its own placeholder, except where Postgres requires
    # two expressions to be the same, as a GROUP BY expression and the same
    # expression in the select list must be. There, equal constants in the
    # same places share one placeholder (see Sharing for the list, and for
    # keys written by position or alias), and the map holds it once. It's
    # numbered where its first constant sits. The search for a key's copies
    # covers the whole of the other clause, aggregate arguments and FILTER
    # included, so it can share more than Postgres needs, but only
    # constants that hold equal values.
    #
    # == Row counts
    #
    # Redaction.redact also gives each placeholder's shape a "rows" entry,
    # from the step 1 plan node that consumes it: the node whose qual
    # (Filter, Index Cond, Join Filter, Hash Cond, and the like) holds a
    # literal that matches it. "status" is "found", with the node's type,
    # the qual, and its estimated rows, actual rows, and loops; "none",
    # when no qual holds it, as when Postgres folded it or it's a LIMIT; or
    # "ambiguous", when quals of more than one node hold it. A value two
    # placeholders share matches both, so each gets the rows only if every
    # literal with that value is in one node.
    #
    # Trust boundary: the redacted query and plan and the shapes are
    # shape-class. The placeholder map holds the literals, so it's
    # value-class and stays in the store. inspect shows neither the map
    # nor any value, and no error quotes one.
    module Redaction
      # Its message is the rule, and the SQLSTATE of a Postgres error, and
      # never quotes the query or a value.
      class Error < StandardError
        attr_reader :rule, :sqlstate

        def initialize(rule, sqlstate = nil)
          @rule = rule
          @sqlstate = sqlstate
          super(sqlstate ? "#{rule} (SQLSTATE #{sqlstate})" : rule)
        end
      end

      # One placeholder. value is the literal as text, or nil for NULL.
      # type is the literal's type for PREPARE (see Literal.of). shape is
      # its shape annotation: "type", the type class (text, integer,
      # numeric, boolean, datetime, or other, from the constant or its
      # cast), "pattern" for a LIKE or ILIKE pattern (where it has
      # wildcards: some of "leading", "inner", and "trailing", in that
      # order, or [] for none), and "elements"
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

      RedactedPlan = Data.define(:explain, :masked, :dropped)

      # The whole of 3g for the step 1 inputs.
      Redacted = Data.define(:query, :plan, :placeholder_map, :placeholder_shapes) do
        # Writes the two store entries: placeholder_map, which never leaves
        # the enclave, and placeholder_shapes, which may.
        def store(store)
          store.write("placeholder_map", placeholder_map)
          store.write("placeholder_shapes", placeholder_shapes)
          nil
        end

        def inspect = "#<data #{self.class} query=#{query.inspect}, placeholder_map=<redacted>>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      module_function

      def redact(parse, explain)
        query = query(parse)
        plan = Plan.new(explain, Matcher.new(query.placeholder_map))
        Redacted.new(query:, plan: redacted_plan(plan), placeholder_map: query.placeholder_map,
                     placeholder_shapes: annotated(query.placeholders, plan.consumers))
      end

      # Each placeholder's shape, with its row counts.
      def annotated(placeholders, consumers)
        placeholders.to_h do |p|
          ["$#{p.number}", p.shape.merge("rows" => Rows.of(consumers.fetch(p.number, []))).freeze]
        end
      end

      def query(parse)
        redacted = Query.new(parse)
        sql = Deparse.faithfully(redacted.tree)
        RedactedQuery.new(sql:, placeholders: redacted.placeholders)
      end

      # explain is the parsed JSON of EXPLAIN (FORMAT JSON), with or without
      # ANALYZE. placeholder_map is RedactedQuery#placeholder_map, or what
      # the store gives back.
      def plan(explain, placeholder_map) = redacted_plan(Plan.new(explain, Matcher.new(placeholder_map)))

      def redacted_plan(plan) = RedactedPlan.new(explain: plan.explain, masked: plan.masked, dropped: plan.dropped)

      # The run's placeholder map, from the store. A stored entry that isn't
      # a placeholder map raises Error bad_placeholder_map.
      def placeholder_map(store) = checked_map(store.read("placeholder_map"))

      # The map, if it's a placeholder map: "$1" through "$N", each with a
      # String or nil value and a type Literal.of gives. Anything else
      # raises Error bad_placeholder_map.
      def checked_map(map)
        numbered = map.is_a?(Hash) && map.keys.sort_by { it.to_s.delete_prefix("$").to_i } ==
                                      (1..map.size).map { "$#{it}" }
        raise Error, "bad_placeholder_map" unless numbered && map.each_value.all? { |entry| entry?(entry) }

        map
      end

      def entry?(entry)
        entry.is_a?(Hash) && entry.keys.sort == %w[type value] && Matcher::TYPES.include?(entry["type"]) &&
          (entry["value"].nil? || entry["value"].is_a?(String))
      end

      # The SQL and the literals the runners need to run a query written with
      # the placeholders (see Binding).
      def binding(sql, placeholder_map) = Bind.for(sql, checked_map(placeholder_map))
    end
  end
end

require_relative "redaction/query"
require_relative "redaction/matcher"
require_relative "redaction/plan"
require_relative "redaction/rows"
require_relative "redaction/binding"
