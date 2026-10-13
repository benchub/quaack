# frozen_string_literal: true

require "quaack/protocol/fuzz_result"

module Quaack
  module Enclave
    # A fuzz disproof's sizes (task 20261012-2), checked against the tables
    # the two queries name before they leave the enclave: by ReportPayload,
    # which sends only sizes that pass, and by egress, which refuses a
    # report whose sizes don't.
    #
    #   tables = FuzzSizes.tables("SELECT o.id FROM public.orders o")  # => [["public", "orders"]]
    #   FuzzSizes.check([["public", "orders", 2]], tables)               # => [["public", "orders", 2]]
    #   FuzzSizes.check([["public", "secret", 2]], tables)               # => nil
    #
    # Trust boundary. Table names are schema. A size goes out only if
    # Protocol::FuzzResult.sizes? passes it, rows a positive count, and its
    # schema and table are a schema-qualified relation one of the queries
    # names (as Fuzz's footprint reads them). A query that doesn't parse
    # names none.
    #
    # Egress loads this file without pg_query (it must load with no gems,
    # see egress_spec), so tables loads the parser only when a report
    # carries sizes.
    module FuzzSizes
      module_function

      # The [schema, name] of every schema-qualified relation the queries name.
      def tables(*sqls)
        require_relative "scenarios"
        sqls.flat_map do |sql|
          next [] unless sql.is_a?(String)

          Scenarios.query_tables(PgQuery.parse(sql).tree).map { [it.schema, it.name] }
        rescue PgQuery::ParseError
          []
        end.uniq
      end

      # sizes, if it's a list whose every entry is a table of tables, or nil.
      def check(sizes, tables)
        sizes if sizes.is_a?(Array) && Protocol::FuzzResult.sizes?(sizes) && sizes.all? { tables.include?(it.take(2)) }
      end

      # Whether a report's rewrites each carry sizes check passes against
      # the original's and that rewrite's tables, or none, and trials that
      # are a count or none. A rewrite's keys may be Strings or Symbols.
      def report?(original_sql, rewrites)
        rewrites.all? do |rewrite|
          sizes = field(rewrite, "sizes")
          (sizes.nil? || check(sizes, tables(original_sql, field(rewrite, "sql")))) &&
            Protocol::FuzzResult.trials?(field(rewrite, "trials"))
        end
      end

      def field(rewrite, key) = rewrite.fetch(key) { rewrite[key.to_sym] }
    end
  end
end
