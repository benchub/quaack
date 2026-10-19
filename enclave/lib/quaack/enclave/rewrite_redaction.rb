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
    # match its key. It's refused (Refusal) when none does,
    # redact_rewrite_no_match, as for a literal with no column context such
    # as a LIMIT or EXISTS's SELECT 1, or when more than one placeholder
    # does, redact_rewrite_ambiguous. The constants Redaction keeps as
    # written, such as a positional ORDER BY, stay as written. Values are
    # never looked at, and no placeholder is ever made up.
    #
    # The result is checked: it parses, and Redaction finds no literal left
    # in it, so none of the run's literals can be there.
    #
    # Trust boundary: the rewrite holds real literals. A Refusal names its
    # rule and the literal's 1-based character position, never the SQL or a
    # value, and has no cause.
    module RewriteRedaction
      class Refusal < StandardError
        attr_reader :rule, :position

        def initialize(rule, position)
          @rule = rule
          @position = position
          super("#{rule} at character #{position}")
        end
      end

      # The internal error for output that still holds a literal.
      class Error < StandardError; end

      Slot = Data.define(:node, :key)

      module_function

      def redact(sql, redacted_query)
        parse = PgQuery.parse(sql)
        originals = slots(PgQuery.parse(redacted_query).tree, &:param_ref)
        literals(parse).each { |slot| slot.node.param_ref = PgQuery::ParamRef.new(number: number(slot, originals, sql)) }
        checked(Deparse.faithfully(parse.tree))
      end

      # The rewrite's constants that Redaction would replace, as Slots.
      def literals(parse)
        locations = Redaction.numbers(parse).keys.to_set
        slots(parse.tree) { (constant = it.a_const) && locations.include?(constant.location) }
      end

      # The placeholder number for slot, or raises Refusal.
      def number(slot, originals, sql)
        numbers = matching(slot, originals)
        return numbers.first if numbers.size == 1

        at = position(sql, slot.node.a_const.location)
        raise Refusal.new("redact_rewrite_no_match", at), cause: nil if numbers.empty?

        raise Refusal.new("redact_rewrite_ambiguous", at), cause: nil
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

      # sql, once it parses and Redaction finds no literal left in it. Each
      # placeholder is swapped for a column first, since Redaction refuses
      # placeholders.
      def checked(sql)
        parse = PgQuery.parse(sql)
        slots(parse.tree, &:param_ref).each do |slot|
          slot.node.column_ref = PgQuery::ColumnRef.new(fields: [PgQuery::Node.from_string("quaack_placeholder")])
        end
        left = Redaction.numbers(PgQuery.parse(parse.deparse))
        raise Error, "the redacted rewrite still holds a literal" unless left.empty?

        sql
      end
    end
  end
end
