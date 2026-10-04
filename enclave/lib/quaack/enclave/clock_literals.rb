# frozen_string_literal: true

require "pg_query"
require_relative "clock_functions"
require_relative "table_name"

module Quaack
  module Enclave
    # The clock-reading literals clock-anchor anchors: 'now', 'today', 'yesterday',
    # and 'tomorrow', where Postgres reads them as a date or timestamp.
    # They read the clock just as now() does (DESIGN.md's clock-anchor).
    #
    #   found = ClockLiterals.find(placeholder_map, statistics) { |column_names| LiteralSet.feeds(parse, column_names) }
    #   # => Found(words: {1 => "today"}, types: {1 => "timestamptz"})
    #   ClockLiterals.anchored_node(node, found)   # => the node that replaces node, or nil
    #
    # redact has already made each literal a placeholder, so the words come
    # from the placeholder map: an untyped string ("unknown") that is one of
    # the words, in any case and with whitespace around it, as Postgres
    # reads it. Anything longer, such as 'today 12:00', or a real date, is
    # left alone.
    #
    # A placeholder is replaced where Postgres gives it a date or timestamp
    # type, in one of two ways:
    # - A cast: $n::date, ::timestamp, or ::timestamptz, with any
    #   precision. 'now' as a time or timetz reads the clock too; the other
    #   words aren't valid times.
    # - A comparison with a column (col = $n, col < $n, BETWEEN, IN, as
    #   literals's feeds find them) whose type, from statistics's clock_columns, is date,
    #   timestamp, or timestamptz. A placeholder redact shares isn't one.
    #
    # The replacement is the word's value from the anchor, cast to the
    # target type: 'now' is quaack.clock_anchor(), 'today' its date,
    # 'yesterday' and 'tomorrow' that date minus or plus 1. Casting the date
    # to a timestamp gives midnight in the session's TimeZone, as Postgres
    # reads 'today'.
    #
    # Trust boundary: the words are the only values read, and they appear
    # nowhere in the output. The replacement records the placeholder, which
    # is shape.
    module ClockLiterals
      WORD = /\A\s*(now|today|yesterday|tomorrow)\s*\z/i
      DATE_TYPES = %w[date timestamp timestamptz].freeze
      TIME_TYPES = %w[time timetz].freeze

      ANCHOR = ClockFunctions::ANCHOR
      BASES = {
        "now" => ANCHOR, "today" => "#{ANCHOR}::pg_catalog.date",
        "yesterday" => "#{ANCHOR}::pg_catalog.date - 1", "tomorrow" => "#{ANCHOR}::pg_catalog.date + 1"
      }.freeze

      Found = Data.define(:words, :types)

      module_function

      # The clock words by placeholder number, and each one's implicit
      # type, from a column it's compared with, where it has one.
      #
      # The block takes the column names by TableName, and returns literals's
      # feeds for the query (LiteralSet.feeds). It runs only when there are
      # words and statistics.
      def find(placeholder_map, statistics, &)
        words = placeholder_map.to_h.filter_map do |number, entry|
          match = WORD.match(entry["value"].to_s) if entry["type"] == "unknown"
          [Integer(number.delete_prefix("$"), 10), match[1].downcase] if match
        end.to_h
        Found.new(words:, types: words.empty? || statistics.nil? ? {} : implicit_types(statistics, words, &))
      end

      def implicit_types(statistics, words)
        tables = statistics.fetch("tables").to_h { [TableName.new(schema: it["schema"], name: it["name"]), it] }
        feeds = yield tables.transform_values { it["column_names"] }
        words.keys.filter_map do |number|
          type = column_type(tables, feeds["$#{number}"])
          [number, type] if DATE_TYPES.include?(type)
        end.to_h
      end

      def column_type(tables, feed)
        tables[feed.table].fetch("clock_columns", {})[feed.column] if feed.respond_to?(:table)
      end

      # The node that replaces node, or nil when it isn't a clock literal.
      def anchored_node(node, found)
        if node.type_cast&.arg&.param_ref
          explicit(node.type_cast, found)
        elsif node.param_ref
          implicit(node.param_ref.number, found)
        end
      end

      def explicit(cast, found)
        word = found.words[cast.arg.param_ref.number]
        cast(word, cast.type_name) if word && castable?(cast.type_name, word)
      end

      def implicit(number, found)
        type = found.types[number]
        cast(found.words.fetch(number), expression("0::pg_catalog.#{type}").type_cast.type_name) if type
      end

      def castable?(type_name, word)
        type = type_name.names.last.string.sval
        DATE_TYPES.include?(type) || (TIME_TYPES.include?(type) && word == "now")
      end

      def cast(word, type_name)
        PgQuery::Node.new(type_cast: PgQuery::TypeCast.new(arg: expression(BASES.fetch(word)), type_name:))
      end

      def expression(sql)
        PgQuery.parse("SELECT #{sql}").tree.stmts.first.stmt.select_stmt.target_list.first.res_target.val
      end
    end
  end
end
