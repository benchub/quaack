# frozen_string_literal: true

require "pg_query"
require_relative "clock_literals"
require_relative "pg_array"
require_relative "planner_statistics"
require_relative "predicate_atoms"
require_relative "redaction"
require_relative "table_name"

module Quaack
  module Enclave
    # DESIGN.md's literals: the slow, worst-case, and typical literal sets, from redact's
    # placeholder map and statistics' statistics, kept in the governed store.
    #
    #   result = LiteralSet.run(store:, sql: redacted.query.sql)
    #   result.sets["worst_case"]   # => {"$1" => {"value" => "7", "type" => "integer"}, ...}
    #   result.fallbacks            # => {"worst_case" => {"$2" => "no_mcv"}, "typical" => {}}
    #   LiteralSet.load(store)      # => the same Result, from the store
    #   Redaction.binding(sql, result.sets["typical"])   # binds a set as redact binds the slow one
    #
    # sql is the redacted query's SQL (Redaction::Redacted#query.sql),
    # passed in because redact doesn't store it. It must bind against the
    # stored placeholder map (see Redaction.binding), or Redaction::Error is
    # raised. The statistics come from statistics' stored entry.
    #
    # Each set is a placeholder map, keyed by redact's numbers, in the form
    # Redaction.binding takes, so any set binds the way the slow one does.
    # slow is redact's map itself. The other two start from it, and each
    # placeholder that feeds a column predicate takes a value from that
    # column's pg_stats row, picked by the operator:
    # - col = $n: worst case, the top MCV (pg_stats lists the most common
    #   first); typical, the middle histogram bound.
    # - col < $n and col <= $n: worst case, the last histogram bound, which
    #   selects the most rows; > and >=, the first. Typical, the middle one.
    # - col BETWEEN $a AND $b: worst case, the first and last bounds.
    #   Typical, the middle bound and the one after it: the middle bucket.
    #   A lower (> or >=) and an upper (< or <=) bound on one column, in
    #   the same AND, as in created_at >= $1 AND created_at < $2, pair up
    #   the same way. A range on its own keeps the rule above.
    # - col IN ($a, $b, ...) and col = ANY(ARRAY[$a, ...]): the list keeps
    #   its length. Worst case, element i takes the ith most common value.
    #   Typical, the elements take consecutive bounds around the middle.
    # - col = ANY($n), with $n an array literal: the same, written as one
    #   array of as many elements.
    # The column may sit on either side, as in $n < col. A placeholder may
    # be cast to the column's own type, as psycopg2 writes Django's dates
    # and lists, $1::timestamptz against a timestamptz column, or
    # col = ANY($1::bigint[]) on a bigint one: the type's name, bare or
    # under pg_catalog, matches statistics' column_types for the column,
    # with no modifier. The cast stays in the SQL, and reads the picked
    # pg_stats text as the column does.
    #
    # A placeholder keeps its slow value in a set where it can't get one,
    # and fallbacks records why, by set and placeholder:
    # - operator: LIKE, ILIKE, <>, NOT IN, NOT BETWEEN, BETWEEN SYMMETRIC,
    #   IS [NOT] DISTINCT FROM, and <> ALL keep the slow literal in all
    #   three sets.
    # - unsupported_shape, the v1 limits: the placeholder isn't one side of
    #   a comparison with a plain column of a table in the statistics, such
    #   as an expression or function on the column (lower(c.email) = $1), a
    #   cast to another type than the column's or with a modifier
    #   ($1::date against a timestamptz column, $1::numeric(3, 0)), a
    #   column of a subquery or CTE, a join
    #   compared through a subquery, a LIMIT, or a literal in a keyset row
    #   comparison, (a, b) < ($1, $2). An array literal that
    #   isn't one-dimensional counts too.
    # - shared_placeholder: redact shares it between expressions Postgres
    #   requires to match, so it can feed more than one place.
    # - no_statistics: the column has no pg_stats row.
    # - no_mcv and no_histogram: the pick needs a value the column's
    #   statistics don't have, such as the top MCV of a unique column, or
    #   an IN element past the end of the MCV list.
    # - type_mismatch: the value doesn't read as the placeholder's type.
    # - clock_literal: a clock-reading word, such as 'today', compared with
    #   a date or timestamp column, which clock-anchor anchors (see ClockLiterals).
    #
    # Types: a picked value is pg_stats's text for it, and keeps the
    # placeholder's declared type, so Binding declares it as it declares
    # the slow literal. An unknown one (an untyped string) takes its type
    # from the column, as the literal did. A number placeholder widens to
    # bigint or numeric when the value needs it, as 20 against a numeric
    # column's 7.5. A boolean one takes pg_stats's t or f. Any other value
    # that doesn't read as the type, and any value for a bit string
    # placeholder, falls back (type_mismatch).
    #
    # Trust boundary: the sets hold real values, so they stay in the store,
    # and nothing here goes out. inspect leaves the sets out. Errors name
    # only a rule: Error bad_statistics for a stored statistics entry it
    # can't read, and bad_literal_sets for a stored entry that isn't this.
    module LiteralSet
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end

      ENTRY = "literal_sets"
      SETS = %w[slow worst_case typical].freeze
      PICKED = %w[worst_case typical].freeze

      Result = Data.define(:sets, :fallbacks) do
        def inspect = "#<data #{self.class} sets=<redacted>, fallbacks=#{fallbacks}>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      # One placeholder's place in a column predicate: its role, and for
      # a list element, its index and the list's length.
      Feed = Data.define(:table, :column, :role, :index, :count)

      module_function

      def run(store:, sql:)
        map = Redaction.placeholder_map(store)
        Redaction.binding(sql, map)
        statistics = store.read(PlannerStatistics::ENTRY)
        tables = Tables.new(statistics)
        result = Picker.new(map, feeds_for(PgQuery.parse(sql), tables, map, statistics), tables).result
        store.write(ENTRY, result.sets.merge("fallbacks" => result.fallbacks))
        result
      end

      # "$n" => Feed, or a Symbol for why it feeds no column predicate,
      # for each placeholder in parse.
      def feeds(parse, column_names, column_types = {}) = Feeds.new(parse, column_names, column_types).feeds

      # "$n" => [Feed, ...], one for each place $n appears, for each
      # placeholder every one of whose places feeds a column predicate.
      # ClockLiterals takes it.
      def column_feeds(parse, column_names) = Feeds.new(parse, column_names).columns

      # The feeds, with each clock literal clock-anchor anchors kept slow.
      def feeds_for(parse, tables, map, statistics)
        found = Feeds.new(parse, tables.column_names, tables.column_types)
        clock = ClockLiterals.find(map, statistics) { found.columns }.types.keys
        found.feeds.merge(clock.to_h { ["$#{it}", :clock_literal] })
      end

      # Whether a cast's type_name names type, a pg_catalog type's name,
      # written pg_catalog.int8 or int8 (or an array of it, if array), with
      # no modifier, such as numeric(3, 0)'s, that could change the value.
      def cast_to?(type_name, type, array: false)
        names = type_name.names.map { it.string.sval }
        names = names.drop(1) if names.size == 2 && names.first == "pg_catalog"
        names == [type] && type_name.typmods.empty? && type_name.array_bounds.size == (array ? 1 : 0)
      end

      def load(store)
        entry = store.read(ENTRY)
        raise Error, "bad_literal_sets" unless entry.is_a?(Hash) && entry.keys.sort == [*SETS, "fallbacks"].sort

        Result.new(sets: SETS.to_h { [it, Redaction.checked_map(entry[it])] }, fallbacks: entry["fallbacks"])
      rescue Redaction::Error
        raise Error, "bad_literal_sets", cause: nil
      end

      # statistics' stored tables, keyed by TableName.
      class Tables
        def initialize(data)
          tables = data["tables"] if data.is_a?(Hash)
          bad! unless tables.is_a?(Array) && tables.all? { table?(it) }

          @tables = tables.to_h { [TableName.new(schema: it["schema"], name: it["name"]), it] }
        end

        def column_names = @tables.transform_values { it["column_names"] }

        # Each table's column_types (see PlannerStatistics::ColumnTypes), or {}
        # for an entry stored before it had them.
        def column_types = @tables.transform_values { it["column_types"] || {} }

        # A column's pg_stats row, or nil for none.
        def column(table, name)
          row = @tables.fetch(table)["columns"][name]
          bad! unless row.nil? || (row.is_a?(Hash) && %w[most_common_vals histogram_bounds].all? { list?(row[it]) })
          row
        end

        private

        def table?(table)
          table.is_a?(Hash) && table["schema"].is_a?(String) && table["name"].is_a?(String) &&
            table["column_names"].is_a?(Array) && table["columns"].is_a?(Hash) && types?(table["column_types"])
        end

        def list?(value) = value.nil? || (value.is_a?(Array) && value.all?(String))

        def types?(value)
          value.nil? || (value.is_a?(Hash) && value.all? { |name, type| name.is_a?(String) && type.is_a?(String) })
        end

        def bad! = raise(Error, "bad_statistics")
      end

      # Which column predicate each placeholder feeds: "$n" => Feed, or
      # the reason it feeds none that picks a value.
      class Feeds
        RANGE = { "<" => :below, "<=" => :below, ">" => :above, ">=" => :above }.freeze
        FLIPPED = { "<" => ">", "<=" => ">=", ">" => "<", ">=" => "<=" }.freeze
        PICKED_OPERATORS = ["=", *RANGE.keys, "BETWEEN", "IN", "= ANY"].freeze

        attr_reader :feeds

        def initialize(parse, column_names, column_types = {})
          @parse = parse
          @column_types = column_types
          @feeds = {}
          @fed = Hash.new { |hash, key| hash[key] = [] }
          @ranges = Hash.new { |hash, key| hash[key] = [] }
          PredicateAtoms.extract(parse, column_names:).each { atom(it) }
          pair_ranges
          shared.each { @feeds["$#{it}"] = :shared_placeholder }
        end

        # "$n" => [Feed, ...] for each placeholder that feeds a column
        # predicate everywhere it appears, one Feed per place.
        def columns
          @fed.select { |number, fed| fed.size == counts[Integer(number.delete_prefix("$"), 10)] }
        end

        private

        # The placeholder numbers the query holds more than once.
        def shared = counts.select { |_number, count| count > 1 }.keys

        # How many times the query holds each placeholder number.
        def counts
          @counts ||= Hash.new(0).tap do |counts|
            @parse.walk! do |_parent, _field, node, _location|
              counts[node.number] += 1 if node.is_a?(PgQuery::ParamRef)
            end
          end
        end

        def atom(atom)
          return unless %i[equality range in like].include?(atom.kind)

          expr = PredicateAtoms.node(@parse, atom).a_expr
          return unless expr
          return operator(expr) unless PICKED_OPERATORS.include?(atom.operator)

          column = atom.columns.first
          feed(column, column_sides(expr, atom.operator, column), and_list(atom.path)) if column&.table
        end

        def feed(column, sides, conjunction)
          sides&.each do |number, role, index, count|
            @feeds[number] = Feed.new(table: column.table, column: column.name, role:, index:, count:)
            @fed[number] << @feeds[number]
            @ranges[[conjunction, column.table, column.name]] << number if conjunction && %i[below above].include?(role)
          end
        end

        # The path of the AND's argument list the atom is one of, or nil.
        def and_list(path)
          return nil unless path.length >= 3 && path[-3] == "bool_expr"

          owner = path[0...-3].reduce(@parse.tree) { |node, step| node[step] }
          path[0...-1] if owner.bool_expr.boolop == :AND_EXPR
        end

        # A lower and an upper bound on one column in the same AND, as in
        # created_at >= $1 AND created_at < $2, take BETWEEN's roles.
        def pair_ranges
          @ranges.each_value do |numbers|
            roles = numbers.map { @feeds[it].role }
            next unless roles.include?(:below) && roles.include?(:above)

            numbers.each { |n| @feeds[n] = @feeds[n].with(role: @feeds[n].role == :above ? :from : :to) }
          end
        end

        # A LIKE or another operator's placeholders keep the slow literal.
        def operator(expr)
          [expr.lexpr, expr.rexpr].each do |side|
            items = side&.list ? side.list.items : [side]
            items.each { |item| @feeds["$#{item.param_ref.number}"] = :operator if item&.param_ref }
          end
        end

        # sides, with the column's type for its cast placeholders.
        def column_sides(expr, operator, column)
          @type = @column_types.fetch(column.table, {})[column.name]
          sides(expr, operator)
        end

        # [["$n", role, index, count], ...] for the atom's placeholders, or
        # nil when a side isn't a plain column or a plain placeholder.
        def sides(expr, operator)
          case operator
          when "BETWEEN" then between(expr)
          when "IN" then list(expr.lexpr, expr.rexpr.list.items)
          when "= ANY" then any(expr)
          else compared(expr, operator)
          end
        end

        def compared(expr, operator)
          left = expr.lexpr
          right = expr.rexpr
          left, right, operator = right, left, FLIPPED.fetch(operator, operator) if right.column_ref
          right = placeholder(right)
          return nil unless left.column_ref && right

          # = is a list of one.
          [RANGE.key?(operator) ? [name(right), RANGE[operator]] : [name(right), :element, 0, 1]]
        end

        def between(expr)
          low, high = expr.rexpr.list.items.map { placeholder(it) }
          return nil unless expr.lexpr.column_ref && low && high

          [[name(low), :from], [name(high), :to]]
        end

        def any(expr)
          return nil unless expr.lexpr.column_ref

          array = placeholder(expr.rexpr, array: true)
          return [[name(array), :array]] if array

          list(expr.lexpr, expr.rexpr.a_array_expr&.elements.to_a)
        end

        def list(column, items)
          items = items.map { placeholder(it) }
          return nil unless column.column_ref && !items.empty? && items.all?

          items.each_with_index.map { |item, i| [name(item), :element, i, items.size] }
        end

        def name(node) = "$#{node.param_ref.number}"

        # The placeholder node, plain or cast to the column's own type (an
        # array of it, for = ANY), or nil.
        def placeholder(node, array: false)
          return node if node.param_ref

          node.type_cast&.then { it.arg if it.arg&.param_ref && LiteralSet.cast_to?(it.type_name, @type, array:) }
        end
      end

      # Picks each set's values.
      class Picker
        NUMBERS = %w[integer bigint numeric].freeze
        INT4 = (-(2**31))..((2**31) - 1)
        INT8 = (-(2**63))..((2**63) - 1)
        INTEGER = /\A[+-]?\d{1,30}\z/
        DECIMAL = /\A[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d{1,4})?\z/

        attr_reader :result

        def initialize(map, feeds, tables)
          @tables = tables
          @sets = PICKED.to_h { [it, {}] }
          @fallbacks = PICKED.to_h { [it, {}] }
          map.each { |number, entry| PICKED.each { fill(it, number, entry, feeds.fetch(number, :unsupported_shape)) } }
          @result = Result.new(sets: { "slow" => map, **@sets }, fallbacks: @fallbacks)
        end

        private

        def fill(set, number, entry, feed)
          picked = pick(feed, set, entry)
          @fallbacks[set][number] = picked.to_s if picked.is_a?(Symbol)
          @sets[set][number] = picked.is_a?(Hash) ? picked : entry
        end

        # The entry for the set, or the reason it falls back.
        def pick(feed, set, entry)
          return feed if feed.is_a?(Symbol)

          row = @tables.column(feed.table, feed.column)
          return :no_statistics unless row

          value = feed.role == :array ? array(feed, set, row, entry["value"]) : one(feed, set, row)
          return value if value.is_a?(Symbol)

          type = typed(value, entry["type"])
          type ? { "value" => value, "type" => type } : :type_mismatch
        end

        def one(feed, set, row)
          set == "worst_case" ? worst(feed, row) : typical(feed, row)
        end

        # An element's ith most common value, or the end bound that selects
        # the most rows.
        def worst(feed, row)
          return (row["most_common_vals"] || [])[feed.index] || :no_mcv if feed.role == :element

          bounds = row["histogram_bounds"] || []
          (%i[below to].include?(feed.role) ? bounds.last : bounds.first) || :no_histogram
        end

        def typical(feed, row)
          bounds = row["histogram_bounds"] || []
          middle = bounds.size / 2
          index = case feed.role
                  when :to then middle + 1
                  when :element then start(bounds.size, feed.count) + feed.index
                  else middle
                  end
          bounds[index] || :no_histogram
        end

        # Where count consecutive bounds around the middle start.
        def start(size, count) = ((size / 2) - (count / 2)).clamp(0, [size - count, 0].max)

        # = ANY($n): one array literal, of as many elements as the slow one.
        # An element is quoted, with " and \ escaped, as array_in reads it.
        def array(feed, set, row, slow)
          count = PgArray.parse(slow.to_s).size
          elements = (0...count).map { |index| one(feed.with(role: :element, index:, count:), set, row) }
          elements.find { it.is_a?(Symbol) } ||
            "{#{elements.map { %("#{it.gsub(/["\\]/) { |c| "\\#{c}" }}") }.join(",")}}"
        rescue ArgumentError
          :unsupported_shape
        end

        # The type to bind the value with, or nil if it doesn't read as the
        # placeholder's.
        def typed(value, declared)
          case declared
          when "unknown" then declared
          when *NUMBERS then number_type(value, declared)
          when "boolean" then declared if %w[t f].include?(value)
          end
        end

        def number_type(value, declared)
          needed = if INTEGER.match?(value) then integer_type(Integer(value, 10))
                   elsif DECIMAL.match?(value) then "numeric"
                   end
          needed && NUMBERS[[NUMBERS.index(declared), NUMBERS.index(needed)].max]
        end

        def integer_type(number)
          if INT4.cover?(number) then "integer"
          elsif INT8.cover?(number) then "bigint"
          else "numeric"
          end
        end
      end

      private_constant :Tables, :Feeds, :Picker, :Feed
    end
  end
end
