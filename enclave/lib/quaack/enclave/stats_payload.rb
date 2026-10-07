# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The stats that the llm-index-ideas and llm-rewrites payloads send (DESIGN.md's llm-index-ideas):
    # classify's outbound statistics, with each table's columns cut to the
    # ones the queries reference anywhere.
    #
    #   StatsPayload.subset(store.read("classification")["outbound_statistics"], [store.read("qualified_query")])
    #   # => { "tables" => [{ "schema", "name", "columns" => [only the referenced ones], "indexes", ... }] }
    #
    # pg_query finds every ColumnRef, in any clause, subquery, or CTE, and
    # every USING name. A qualifier resolves to each table the query names
    # with it as alias, table name, or schema and table name. A column
    # whose qualifier resolves to no table (a subquery's or CTE's alias),
    # or that has none, counts for every table that has a column of that
    # name. A star, a whole-row reference, or a NATURAL join keeps every
    # column of the tables it covers, and a bare * keeps them all. A query
    # that won't parse keeps everything. It fails toward sending: what it
    # can't pin down, it keeps.
    #
    # Trimming only removes: each kept column, and each table's other
    # fields, are classify's own, so nothing goes out that the outbound
    # statistics wouldn't already send.
    module StatsPayload
      module_function

      def subset(outbound, sqls)
        refs = sqls.map { references(it) }
        keep = refs.include?(:all) ? :all : refs.reduce(:|)
        { **outbound, "tables" => outbound["tables"].map { trim(it, keep) } }
      end

      def trim(table, keep)
        return table if keep == :all

        names = kept_names(table, keep)
        { **table, "columns" => table["columns"].select { names == :all || names.include?(it["name"]) } }
      end

      # :all, or the column names keep holds for table.
      def kept_names(table, keep)
        return :all if keep.full.any? { matches?(it, table) }

        keep.columns.filter_map { |qualifier, name| name if qualifier.nil? || matches?(qualifier, table) }
      end

      # A qualifier is [schema, name], schema nil when the query left it off.
      def matches?(qualifier, table)
        qualifier[1] == table["name"] && (qualifier[0].nil? || qualifier[0] == table["schema"])
      end

      # What one query references: Keep, or :all.
      Keep = Data.define(:full, :columns) do
        def |(other) = Keep.new(full: full | other.full, columns: columns | other.columns)
      end

      def references(sql)
        tree = PgQuery.parse(sql).tree.to_h
        nodes = []
        walk(tree, nodes)
        aliases = alias_map(nodes)
        Collector.new(aliases).collect(nodes)
      rescue PgQuery::ParseError
        :all
      end

      def walk(node, nodes)
        case node
        when Hash
          node.each do |key, value|
            nodes << [key, value] if %i[range_var column_ref join_expr].include?(key)
            walk(value, nodes)
          end
        when Array then node.each { walk(it, nodes) }
        end
      end

      # Each name a qualifier can use for a table the query names (its
      # alias, its table name, or "schema.name") => the [schema, name]
      # qualifiers it resolves to.
      def alias_map(nodes)
        map = Hash.new { |h, k| h[k] = [] }
        nodes.each do |key, value|
          next unless key == :range_var

          target = [value[:schemaname].to_s.empty? ? nil : value[:schemaname], value[:relname]]
          names(value, target).each { map[it] |= [target] }
        end
        map
      end

      def names(range_var, (schema, name))
        [range_var.dig(:alias, :aliasname), name, schema && "#{schema}.#{name}"].compact
      end

      # Builds one query's Keep from its ColumnRefs and joins.
      class Collector
        def initialize(aliases)
          @aliases = aliases
          @full = []
          @columns = []
        end

        def collect(nodes)
          nodes.each do |key, value|
            return :all if (key == :join_expr && value[:is_natural]) || (key == :column_ref && !scoped?(value))

            using(value) if key == :join_expr
          end
          Keep.new(full: @full.uniq, columns: @columns.uniq)
        end

        private

        def using(join)
          (join[:using_clause] || []).each { @columns << [nil, it.dig(:string, :sval)] }
        end

        # Records one ColumnRef. false when it covers every table: a bare *,
        # or a star whose qualifier resolves to no table.
        def scoped?(ref)
          *qualifier, last = ref[:fields]
          qualifier = qualifier.map { it.dig(:string, :sval) }
          return star_scoped?(qualifier) if last.key?(:a_star)

          name = last.dig(:string, :sval)
          qualifier.empty? ? unqualified(name) : qualified(qualifier, name)
          true
        end

        def star_scoped?(qualifier)
          targets = qualifier.empty? ? [] : resolve(qualifier)
          @full.concat(targets)
          targets.any?
        end

        # A bare name is a column of any table, or a whole-row reference.
        def unqualified(name)
          @full.concat(@aliases[name]) if @aliases.key?(name)
          @columns << [nil, name]
        end

        def qualified(qualifier, name)
          targets = resolve(qualifier)
          return @columns << [nil, name] if targets.empty?

          targets.each { @columns << [it, name] }
        end

        def resolve(qualifier) = @aliases.fetch(qualifier.last(2).join("."), [])
      end
    end
  end
end
