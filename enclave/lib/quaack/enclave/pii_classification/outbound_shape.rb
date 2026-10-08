# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module PiiClassification
      # A refusal. rule is statistics_bad_shape: a statistic that would go
      # out isn't the shape Postgres gives it (see OutboundShape). The
      # message names the table and the field, never the value.
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
          super("#{rule}: #{detail}")
        end
      end

      # Checks that every statistic outbound_statistics lets out is the
      # shape Postgres gives it, so a value a catalog read got wrong, or
      # that a function or type planted on the search_path wrote, is
      # refused rather than sent. It fails closed: anything else raises
      # statistics_bad_shape, naming the table and the field, never the
      # value. MCV values aren't checked, since they're values by design.
      #
      # - A pg_stats row's (a column's, or an index expression's): null_frac
      #   and each MCV frequency a finite number in 0..1, n_distinct a
      #   finite number, and correlation one in -1..1. Each may be nil, as
      #   for a column with no pg_stats row.
      # - A statistics object's: kinds some of d, f, m, and e; each MCV
      #   frequency and base frequency a finite number in 0..1, one of each
      #   per MCV item; each MCV null flag a boolean, one list per MCV item
      #   and one flag per column of the object; n_distinct and
      #   dependencies Postgres's text for pg_ndistinct and pg_dependencies,
      #   whole numbers or numbers keyed by column numbers. Any may be nil
      #   but kinds.
      module OutboundShape
        KINDS = %w[d f m e].freeze
        # A column number: at most 1600 columns (MaxHeapAttributeNumber), and
        # negative for an expression, so four digits. A count: Postgres
        # writes an ndistinct as an int, so ten. A degree is a %f in 0..1,
        # so ten digits on either side of its point is ample.
        ATTNUM = "-?\\d{1,4}"
        ATTNUMS = "#{ATTNUM}(?:, #{ATTNUM})*".freeze
        COUNT = "\\d{1,10}"
        NUMBER = "\\d{1,10}(?:\\.\\d{1,10})?"
        NDISTINCT = /\A\{(?:"#{ATTNUMS}": #{COUNT}(?:, "#{ATTNUMS}": #{COUNT})*)?\}\z/
        DEPENDENCY = "\"#{ATTNUMS} => #{ATTNUM}\": #{NUMBER}".freeze
        DEPENDENCIES = /\A\{(?:#{DEPENDENCY}(?:, #{DEPENDENCY})*)?\}\z/

        # The test each field of a pg_stats row must pass, when it isn't nil.
        ROW_FIELDS = { "null_frac" => :fraction?, "n_distinct" => :finite?, "correlation" => :correlation?,
                       "most_common_freqs" => :fractions? }.freeze
        # The same for a statistics object. kinds may not be nil.
        OBJECT_FIELDS = { "n_distinct" => :ndistinct?, "dependencies" => :dependencies?,
                          "most_common_freqs" => :fractions?, "most_common_base_freqs" => :fractions?,
                          "most_common_val_nulls" => :flag_lists? }.freeze

        module_function

        # Raises unless table, one table of outbound_statistics, is well shaped.
        def check(table)
          name = "#{table["schema"]}.#{table["name"]}"
          table["columns"].each { check_row(name, it) }
          table["indexes"].each { |index| index["columns"].each { check_row(name, it) } }
          table["extended_statistics"].each { check_object(name, it) }
        end

        def check_row(table, row) = check_fields(table, row, ROW_FIELDS)

        def check_object(table, object)
          need(table, "kinds", object["kinds"].is_a?(Array) && object["kinds"].all? { KINDS.include?(it) })
          check_fields(table, object, OBJECT_FIELDS)
          need(table, "most_common_val_nulls", one_list_per_item?(object))
          need(table, "most_common_freqs", one_frequency_per_item?(object))
        end

        def check_fields(table, data, fields)
          fields.each { |field, test| need(table, field, data[field].nil? || send(test, data[field])) }
        end

        def need(table, field, good)
          raise Error.new("statistics_bad_shape", "#{table}'s #{field}") unless good
        end

        def finite?(value) = value.is_a?(Numeric) && value.finite?

        def correlation?(value) = finite?(value) && value.between?(-1, 1)

        def fraction?(value) = finite?(value) && value.between?(0, 1)

        def fractions?(value) = value.is_a?(Array) && value.all? { fraction?(it) }

        def ndistinct?(value) = value.is_a?(String) && NDISTINCT.match?(value)

        def dependencies?(value) = value.is_a?(String) && DEPENDENCIES.match?(value)

        # Null flags come only with MCV items, one list for each, and one
        # flag in each list for each column (key or expression) the object's
        # definition names.
        def one_list_per_item?(object)
          nulls, items = object.values_at("most_common_val_nulls", "most_common_vals")
          return true if nulls.nil?

          width = column_count(object["definition"])
          items.is_a?(Array) && nulls.size == items.size && !width.nil? && nulls.all? { it.size == width }
        end

        # Frequencies and base frequencies come together, one of each per
        # MCV item. MCV items may be left out (see PiiClassification), but
        # when they're in, the counts must match them.
        def one_frequency_per_item?(object)
          freqs, bases, items = object.values_at("most_common_freqs", "most_common_base_freqs", "most_common_vals")
          return bases.nil? && items.nil? if freqs.nil?

          !bases.nil? && bases.size == freqs.size && (items.nil? || (items.is_a?(Array) && items.size == freqs.size))
        end

        # How many columns a CREATE STATISTICS definition names, or nil
        # when it won't parse as one.
        def column_count(definition)
          stmts = PgQuery.parse(definition).tree.stmts
          stmts.first.stmt.create_stats_stmt&.exprs&.size if stmts.size == 1
        rescue PgQuery::ParseError, TypeError
          nil
        end

        def flag_lists?(value)
          value.is_a?(Array) && value.all? { |flags| flags.is_a?(Array) && flags.all? { [true, false].include?(it) } }
        end
      end
    end
  end
end
