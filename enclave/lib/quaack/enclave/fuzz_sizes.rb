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

      # How many tables the queries name, up to Protocol::FuzzResult::MAX_TABLES
      # (task 20261012-31): a count, never a name.
      # A bare relation name that isn't a CTE in scope counts too (task
      # 20261114-222449-1), as its own table even if it may be a qualified
      # one counted already: more tables claims the bound later, the safe
      # side.
      def count(*sqls)
        require_relative "scenarios"
        found = sqls.flat_map do |sql|
          next [] unless sql.is_a?(String)

          relations(PgQuery.parse(sql).tree, [])
        rescue PgQuery::ParseError
          []
        end
        [found.uniq.size, Protocol::FuzzResult::MAX_TABLES].min
      end

      # [schema, name] of each relation node reads, schema nil when bare,
      # skipping bare names in ctes, the CTE names in scope. A WITH's
      # names are in scope for its statement; within the WITH, a CTE body
      # sees the CTEs before it, and itself too when RECURSIVE.
      def relations(node, ctes, found = [])
        if node.is_a?(PgQuery::RangeVar) && !(node.schemaname.empty? && ctes.include?(node.relname))
          found << [node.schemaname.empty? ? nil : node.schemaname, node.relname]
        end
        scope = with_scope(node, ctes, found)
        unscoped_children(node).each { relations(it, scope, found) }
        found
      end

      # ctes plus the CTE names node's WITH adds, after walking each CTE
      # body with the names it sees.
      def with_scope(node, ctes, found)
        with = node.respond_to?(:with_clause) && node.with_clause
        return ctes unless with

        with.ctes.each_with_object(ctes.dup) do |c, scope|
          cte = c.common_table_expr
          scope << cte.ctename if with.recursive
          relations(cte.ctequery, scope.dup, found)
          scope << cte.ctename
        end
      end

      # node's children other than its WITH, which with_scope walks.
      def unscoped_children(node)
        return ValuePools::Sides.children(node) unless node.is_a?(Google::Protobuf::MessageExts)

        node.class.descriptor.reject { it.name == "with_clause" }.map { it.get(node) }
      end

      # sizes, if it's a list whose every entry is a table of tables, or nil.
      def check(sizes, tables)
        sizes if sizes.is_a?(Array) && Protocol::FuzzResult.sizes?(sizes) && sizes.all? { tables.include?(it.take(2)) }
      end

      # Whether a report's rewrites each carry sizes check passes against
      # the original's and that rewrite's tables, or none, trials, worlds
      # bound and tables that Protocol::FuzzResult.counts? passes, and a fuzz_stop
      # that Protocol::FuzzResult.stop? passes (task 20261016-4). A
      # rewrite's keys may be Strings or Symbols.
      def report?(original_sql, rewrites)
        rewrites.all? do |rewrite|
          sizes = field(rewrite, "sizes")
          (sizes.nil? || check(sizes, tables(original_sql, field(rewrite, "sql")))) &&
            Protocol::FuzzResult.counts?(%w[trials worlds bound tables].to_h { [it, field(rewrite, it)] }) &&
            Protocol::FuzzResult.stop?(field(rewrite, "fuzz_stop"))
        end
      end

      def field(rewrite, key) = rewrite.fetch(key) { rewrite[key.to_sym] }
    end
  end
end
