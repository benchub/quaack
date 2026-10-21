# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "redaction"
require_relative "rewrite_redaction/comparison"

module Quaack
  module Enclave
    # DESIGN.md's redact-rewrite: an operator's rewrite, written with real
    # literals, with each literal replaced by the placeholder of the
    # original's literal in the same comparison.
    #
    #   RewriteRedaction.redact(rewrite_sql, store.read("redacted_query"))
    #   # => the rewrite's SQL with $n in place of each literal
    #
    # Redaction decides which constants are literals, for both sides, so
    # they agree: Redaction.numbers on the rewrite, and the original's $n
    # placeholders. Each one's comparison is the innermost operator
    # (A_Expr) or function call (FuncCall) above it whose other operands
    # name a column, within one SELECT and outside AND, OR, and NOT. Its key
    # is that node's operator or function name and kind, which operand the
    # literal is in, the path from that operand down to the literal (so an
    # IN list's or BETWEEN's slot, and any cast or arithmetic around it),
    # and the columns the other operands name, each with its table: an
    # alias resolved to the table's name, schema dropped, and an
    # unqualified column given the one table of its SELECT's FROM, or none.
    # Two keys match when all of that is equal, a column with no table
    # matching the same column of any table.
    #
    # A rewrite's literal takes the placeholder whose comparisons alone
    # match its key. When several do, the run's placeholder map breaks the
    # tie (20261020-1): the lowest of those whose original literal has the
    # rewrite's text and type, since each binds the same value. A literal
    # with no column comparison in a LIMIT, an OFFSET, or an EXISTS's
    # target list gets a structural key (Comparison.structural). It's
    # refused (Refusal) when none matches, redact_rewrite_no_match, or
    # when the values don't break the tie, redact_rewrite_ambiguous,
    # with the candidates' numbers. An IN list member matches only in a
    # list of the same length (Comparison::Key#size). An integer 1 in an
    # EXISTS's target list that no placeholder matches stays as written
    # (20261020-7); any other constant there is refused. The constants
    # Redaction keeps as written, such as a positional ORDER BY, stay as
    # written. Values are compared only in the enclave and never go out,
    # and no placeholder is ever made up.
    #
    # The result is checked: it parses, and Redaction finds no literal left
    # in it, so none of the run's literals can be there (Error,
    # redact_rewrite_literal_left).
    #
    # Trust boundary: the rewrite holds real literals. A Refusal names its
    # rule, the literal's 1-based character position, and for an ambiguous
    # one the candidate $n numbers, never the SQL or a value, and has no cause.
    module RewriteRedaction
      class Refusal < StandardError
        attr_reader :rule, :position, :candidates

        # candidates: the $n numbers an ambiguous literal could take, or nil.
        def initialize(rule, position, candidates = nil)
          @rule = rule
          @position = position
          @candidates = candidates
          super([[rule, ("at character #{position}" if position)].compact.join(" "),
                 candidates&.map { "$#{it}" }&.join(", ")].compact.join(", candidates "))
        end
      end

      # The error for output that still holds a literal: a QUAACK bug, not
      # the operator's, so it isn't a Refusal (usage), but it has its own rule.
      class Error < StandardError
        def rule = "redact_rewrite_literal_left"
      end

      Slot = Data.define(:node, :key)

      module_function

      # placeholder_map is the run's (Redaction.placeholder_map), read only
      # to break a tie between placeholders whose comparisons all match.
      def redact(sql, redacted_query, placeholder_map = {})
        parse = parsed(sql)
        values = Redaction.literals(parse)
        originals = slots(PgQuery.parse(redacted_query).tree, &:param_ref)
        literals(parse).each do |slot|
          found = number(slot, originals, sql, values.fetch(location(slot)), placeholder_map)
          place(slot, found) if found
        end
        checked(Deparse.faithfully(parse.tree))
      end

      # sql's parse, if it's one statement. Otherwise it raises Refusal:
      # redact_rewrite_unparsable, with pg_query's position when it gives one,
      # and never its message, which quotes the SQL; redact_rewrite_empty; or
      # redact_rewrite_not_one_statement. Redaction refuses one that isn't a
      # SELECT as unsupported_construct, as rewrite-check does.
      def parsed(sql)
        parse = begin
          PgQuery.parse(sql)
        rescue PgQuery::ParseError => e
          raise Refusal.new("redact_rewrite_unparsable", parse_position(sql, e.location)), cause: nil
        end
        count = parse.tree.stmts.size
        raise Refusal.new("redact_rewrite_empty", nil), cause: nil if count.zero?
        raise Refusal.new("redact_rewrite_not_one_statement", nil), cause: nil if count > 1

        parse
      end

      # pg_query's error location is Postgres's cursor position: already a
      # 1-based character position, not a byte offset. Kept only in range.
      def parse_position(sql, location)
        location if location.instance_of?(Integer) && location.between?(1, sql.length + 1)
      end

      def location(slot) = slot.node.a_const.location

      def place(slot, number) = slot.node.param_ref = PgQuery::ParamRef.new(number:)

      # The rewrite's constants that Redaction would replace, as Slots.
      def literals(parse)
        locations = Redaction.numbers(parse).keys.to_set
        slots(parse.tree) { (constant = it.a_const) && locations.include?(constant.location) }
      end

      # The placeholder number for slot, nil to keep it as written, or raises Refusal.
      def number(slot, originals, sql, value, placeholder_map)
        numbers = matching(slot, originals)
        return numbers.first if numbers.size == 1
        return unmatched(slot, sql, value) if numbers.empty?

        at = position(sql, location(slot))

        tied(numbers, value, placeholder_map) or
          raise Refusal.new("redact_rewrite_ambiguous", at, numbers.sort), cause: nil
      end

      # nil for a kept 1, or raises Refusal redact_rewrite_no_match.
      def unmatched(slot, sql, value)
        raise Refusal.new("redact_rewrite_no_match", position(sql, location(slot))), cause: nil unless
          kept?(slot, value)
      end

      # An EXISTS's target list never changes its result, so an integer 1
      # there isn't data (20261020-7). Only that one value is kept; any
      # other constant there is refused, so no real value leaves this way.
      ONE = { "value" => "1", "type" => "integer" }.freeze

      def kept?(slot, value) = value == ONE && Comparison.exists_target?(slot.key)

      # Of several matching numbers, the lowest whose original literal is
      # value (the same text and type), or nil for none. Each such number
      # binds the same value, so which one is taken doesn't change the result.
      def tied(numbers, value, placeholder_map)
        numbers.select { placeholder_map["$#{it}"] == value }.min
      end

      # The numbers of the originals' placeholders whose comparisons match slot's.
      def matching(slot, originals)
        originals.filter_map { it.node.param_ref.number if Comparison.match?(slot.key, it.key) }.uniq
      end

      # A byte offset as a 1-based character position.
      def position(sql, location) = sql.byteslice(0, location).length + 1

      # Every PgQuery::Node the block picks, each a Slot with its
      # Comparison key (nil for none), in tree order.
      def slots(tree, &pick)
        found = []
        walk(tree, [], found, pick)
        found
      end

      # ancestors: [[message, field name, index], ...] from the root down.
      def walk(message, ancestors, found, pick)
        return found << Slot.new(node: message, key: Comparison.key(ancestors)) if picked?(message, pick)

        Comparison.each_child(message) { |name, i, child| walk(child, ancestors + [[message, name, i]], found, pick) }
      end

      def picked?(message, pick) = message.is_a?(PgQuery::Node) && pick.call(message)

      # sql, once it parses and Redaction finds no literal left in it but
      # an EXISTS's kept 1. Each placeholder is swapped for a column first,
      # since Redaction refuses placeholders.
      def checked(sql)
        parse = PgQuery.parse(sql)
        slots(parse.tree, &:param_ref).each do |slot|
          slot.node.column_ref = PgQuery::ColumnRef.new(fields: [PgQuery::Node.from_string("quaack_placeholder")])
        end
        raise Error, "the redacted rewrite still holds a literal" unless left(PgQuery.parse(parse.deparse)).empty?

        sql
      end

      # The literals Redaction finds in parse, but an EXISTS's kept 1.
      def left(parse)
        values = Redaction.literals(parse)
        literals(parse).reject { kept?(it, values.fetch(location(it))) }
      end
    end
  end
end
