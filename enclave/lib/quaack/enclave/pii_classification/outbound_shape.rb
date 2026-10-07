# frozen_string_literal: true

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
      #   frequency and base frequency a finite number in 0..1; each MCV
      #   null flag a boolean, one list per MCV item; n_distinct and
      #   dependencies Postgres's text for pg_ndistinct and pg_dependencies,
      #   whole numbers or numbers keyed by column numbers. Any may be nil
      #   but kinds.
      module OutboundShape
        KINDS = %w[d f m e].freeze
        ATTNUMS = "-?\\d+(?:, -?\\d+)*"
        NUMBER = "\\d+(?:\\.\\d+)?"
        NDISTINCT = /\A\{(?:"#{ATTNUMS}": \d+(?:, "#{ATTNUMS}": \d+)*)?\}\z/
        DEPENDENCY = "\"#{ATTNUMS} => -?\\d+\": #{NUMBER}".freeze
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

        def flag_lists?(value)
          value.is_a?(Array) && value.all? { |flags| flags.is_a?(Array) && flags.all? { [true, false].include?(it) } }
        end
      end
    end
  end
end
