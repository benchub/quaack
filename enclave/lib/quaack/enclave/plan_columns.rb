# frozen_string_literal: true

require_relative "statistics"
require_relative "plan_expression"

module Quaack
  module Enclave
    # Maps a plan's relations and columns to the Statistics tables, and sorts
    # its conditions into conjuncts, for GeneratorTwo. It's private to the
    # enclave namespace.
    #
    # A scan's "Relation Name" has no schema unless the plan was made with
    # VERBOSE, which adds "Schema". Without one, the relation is the
    # Statistics table with that name. If several schemas have it, schemas
    # narrows them to the ones the query touches. If that still leaves more
    # than one, or there's none, the relation maps to nothing.
    #
    # Columns map through the scans' "Alias", which Postgres keeps unique
    # within a plan. A scan's own quals print its columns bare, unless the
    # plan was made with VERBOSE. Other nodes qualify them with an alias,
    # except in a plan with a single alias, where they're bare too. A column
    # that maps to no relation, or isn't in its table's column_names (such as
    # a system column), maps to nothing.
    class PlanColumns
      # A column of a relation in the plan. table is its TableStatistics.
      Column = Data.define(:alias_name, :table, :name)

      # One conjunct of a condition. kind is :constant (a column = a literal
      # or a parameter), :join (a column = a column under another alias), or
      # :other. columns are the mapped columns it uses.
      Conjunct = Data.define(:node, :kind, :columns) do
        def inspect = "#<#{self.class} #{kind}>"
        alias_method :to_s, :inspect
      end

      attr_reader :sole_alias

      def initialize(nodes, statistics, schemas)
        @statistics = statistics
        @schemas = schemas
        @scans = nodes.select(&:alias_name).to_h { |scan| [scan.alias_name, scan] }
        @sole_alias = @scans.keys.first if @scans.size == 1
      end

      def inspect = "#<#{self.class}>"

      # The scan node for an alias, or nil.
      def scan(alias_name) = @scans[alias_name]

      # The TableStatistics for a scan node, or nil.
      def table(node)
        return nil unless node.relation

        matches = named(node)
        matches = matches.select { |t| @schemas.include?(t.name.schema) } if matches.size > 1 && @schemas
        matches.first if matches.size == 1
      end

      # The Column that name parts, such as ["o", "id"] or ["id"], refer to.
      # A bare name belongs to default_alias.
      def resolve(parts, default_alias)
        alias_name, name = parts.size == 1 ? [default_alias, *parts] : parts
        table = table(@scans[alias_name]) if parts.size <= 2 && @scans.key?(alias_name)
        Column.new(alias_name:, table:, name:) if table&.column_names&.include?(name)
      end

      # The conjuncts of the node's conditions under the given keys, such as
      # "Filter". A bare column belongs to default_alias.
      def conjuncts(node, keys, default_alias)
        keys.flat_map { |key| PlanExpression.conjuncts(node[key]).map { |c| conjunct(c, default_alias) } }
      end

      # The leading Sort Keys that are plain columns of the first key's
      # relation, as [Column, direction, nulls].
      def sort_keys(texts)
        keys = []
        strings(texts).each do |text|
          key = key_column(text)
          break unless key && (keys.empty? || keys.first.first.alias_name == key.first.alias_name)

          keys << key
        end
        keys
      end

      # The Group Keys that are plain columns, in order.
      def group_columns(texts) = strings(texts).filter_map { |text| key_column(text)&.first }

      private

      # The tables with the node's relation name, and its schema if the plan
      # has one.
      def named(node)
        @statistics.tables.values.select do |t|
          t.name.name == node.relation && [nil, t.name.schema].include?(node.schema)
        end
      end

      def strings(texts) = Array(texts)

      def key_column(text)
        expression, direction, nulls = PlanExpression.sort_key(text)
        column = column(expression, sole_alias) if expression
        [column, direction, nulls] if column
      end

      def column(node, default_alias)
        parts = PlanExpression.column_parts(node)
        resolve(parts, default_alias) if parts
      end

      def conjunct(node, default_alias)
        sides = PlanExpression.equality_sides(node)
        columns = sides&.map { |side| column(side, default_alias) }
        join(node, columns) || constant(node, sides, columns) ||
          Conjunct.new(node:, kind: :other,
                       columns: PlanExpression.column_refs(node).filter_map { |p| resolve(p, default_alias) })
      end

      def join(node, columns)
        return nil unless columns&.all? && columns.map(&:alias_name).uniq.size == 2

        Conjunct.new(node:, kind: :join, columns:)
      end

      def constant(node, sides, columns)
        return nil unless sides&.any? { |side| PlanExpression.constant?(side) } && columns.compact.size == 1

        Conjunct.new(node:, kind: :constant, columns: columns.compact)
      end
    end

    private_constant :PlanColumns
  end
end
