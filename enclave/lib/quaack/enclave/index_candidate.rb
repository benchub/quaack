# frozen_string_literal: true

require "pg_query"
require_relative "table_name"
require_relative "index_sql"

module Quaack
  module Enclave
    # One proposed index, as the mechanical generators emit it (README 5a-1
    # and 5a-2) and as the filter and tests downstream consume it (5a-3,
    # 5a-4). It has no expression keys, opclasses, or collations.
    #
    #   IndexCandidate.new(
    #     table: TableName.new(schema: "public", name: "orders"),
    #     key: ["customer_id", IndexCandidate::KeyColumn.new(name: "created_at", direction: :desc)],
    #     include: ["total"],              # default []
    #     access_method: :btree,           # default :btree
    #     predicate: "status = 'open'",    # default nil
    #     sources: [:parse]                # the generators that proposed it
    #   ).to_ddl
    #   # => "CREATE INDEX ON public.orders USING btree (customer_id, created_at DESC)
    #   #     INCLUDE (total) WHERE status = 'open'"
    #
    # A bare String in key is an ascending column. Column and table names are
    # real catalog names, unquoted. to_ddl quotes them. The DDL has no index
    # name, which both Postgres and HypoPG allow. Only btree takes a
    # non-default direction or nulls ordering.
    #
    # The predicate is parsed at construction and stored as pg_query deparses
    # it, so "(status = 'open')" and "status = 'open'" make equal candidates.
    # Casts don't normalize away: "status::text = 'open'" stays different.
    #
    # Equality and hash ignore sources, so two generators' copies of the same
    # definition collapse in a Set or a Hash. merge_sources combines them.
    # Key order and INCLUDE order both count.
    #
    # A candidate with a predicate is value-class data under the README's trust
    # boundary, because the predicate can hold a real literal. So inspect,
    # to_s, pp, and every error message leave the predicate text out. Only
    # to_ddl, the predicate reader, and to_h give it back.
    IndexCandidate = Data.define(:table, :key, :include, :access_method, :predicate, :sources) do
      # One keyword per member, which is more than the cop allows.
      def initialize(table:, key:, sources:, include: [], access_method: :btree, predicate: nil) # rubocop:disable Metrics/ParameterLists
        raise ArgumentError, "table must be a schema-qualified TableName" unless table.is_a?(TableName)

        key = key_columns(key)
        access_method = normalize_access_method(access_method)
        check_ordering(key, access_method)
        super(table:, key:, include: include_columns(include, key), access_method:,
              predicate: normalize_predicate(predicate), sources: sources.to_set(&:to_sym).freeze)
      end

      # Reads one CREATE INDEX, as pg_get_indexdef prints it, into a candidate
      # with the given sources. The index name is dropped: TableStatistics
      # keeps it as the key of its indexes map. Returns nil for an index this
      # shape can't represent: UNIQUE, expression keys, opclasses, collations,
      # ON ONLY, WITH options, TABLESPACE, an unqualified table, or anything
      # the constructor refuses. Raises ArgumentError if the SQL isn't exactly
      # one CREATE INDEX. No error message includes the SQL.
      def self.from_ddl(sql, sources:) = IndexSql.read_index(sql, sources)

      # Everything but sources.
      def definition = [table, key, include, access_method, predicate]

      def ==(other) = other.is_a?(IndexCandidate) && definition == other.definition

      def eql?(other) = other.is_a?(IndexCandidate) && definition.eql?(other.definition)

      def hash = [IndexCandidate, definition].hash

      # Like Data's own inspect, but with the predicate redacted.
      def inspect
        shown = to_h.map do |member, value|
          "#{member}=#{member == :predicate && value ? "<redacted>" : value.inspect}"
        end
        "#<data #{self.class} #{shown.join(", ")}>"
      end

      alias_method :to_s, :inspect

      def pretty_print(pp) = pp.text(inspect)

      # A copy of this candidate with the other's sources added. The other
      # must have the same definition.
      def merge_sources(other)
        raise ArgumentError, "can't merge sources from a candidate with a different definition" unless self == other

        with(sources: sources | other.sources)
      end

      # CREATE INDEX DDL, built as a pg_query parse tree and deparsed. This is
      # the one output that holds the predicate's literals.
      def to_ddl
        PgQuery.deparse_stmt(
          PgQuery::IndexStmt.new(
            relation:,
            access_method: access_method.to_s,
            index_params:,
            index_including_params: include.map { |c| index_param(c, :asc, :last) },
            where_clause: predicate && IndexSql.parse_predicate(predicate)
          )
        )
      end

      private

      def key_columns(key)
        columns = key.map { |k| k.is_a?(IndexCandidate::KeyColumn) ? k : IndexCandidate::KeyColumn.new(name: k) }.freeze
        raise ArgumentError, "key must have at least one column" if columns.empty?

        columns
      end

      def include_columns(include, key)
        columns = include.map { |c| column_name(c) }.freeze
        both = key.map(&:name) & columns
        raise ArgumentError, "columns in both the key and INCLUDE: #{both.map(&:inspect).join(", ")}" if both.any?

        columns
      end

      def column_name(name)
        return name.dup.freeze if name.is_a?(String) && !name.empty?

        raise ArgumentError, "column name must be a non-empty String, got #{name.inspect}"
      end

      # Any plain identifier, so a method this doesn't know about still works.
      def normalize_access_method(method)
        name = method.to_s.downcase
        return name.to_sym if /\A[a-z_][a-z0-9_]*\z/.match?(name)

        raise ArgumentError, "index method must be a plain identifier, got #{method.inspect}"
      end

      # Of the built-in methods, only btree can order its entries. Postgres
      # refuses DESC or NULLS FIRST/LAST on any other, even where HypoPG
      # doesn't.
      def check_ordering(key, access_method)
        return if access_method == :btree || key.all?(&:default_order?)

        raise ArgumentError, "only btree takes a non-default direction or nulls ordering, not #{access_method}"
      end

      def normalize_predicate(sql)
        return nil if sql.nil?
        raise ArgumentError, "predicate must be SQL text or nil" unless sql.is_a?(String) && !sql.strip.empty?

        IndexSql.normalize_predicate(sql)
      end

      def index_params = key.map { |k| index_param(k.name, k.direction, k.nulls) }

      def relation
        PgQuery::RangeVar.new(schemaname: table.schema, relname: table.name, inh: true, relpersistence: "p")
      end

      # Leaves out whatever matches Postgres's defaults, so the DDL reads
      # the way a person would write it.
      def index_param(name, direction, nulls)
        nulls_ordering = if nulls == IndexCandidate::KeyColumn::DEFAULT_NULLS.fetch(direction)
                           :SORTBY_NULLS_DEFAULT
                         else
                           nulls == :first ? :SORTBY_NULLS_FIRST : :SORTBY_NULLS_LAST
                         end
        ordering = direction == :desc ? :SORTBY_DESC : :SORTBY_DEFAULT
        PgQuery::Node.new(index_elem: PgQuery::IndexElem.new(name:, ordering:, nulls_ordering:))
      end
    end

    # One column of an index key. direction is :asc or :desc. nulls is :first
    # or :last. When nulls is omitted, it takes Postgres's default for the
    # direction (last for asc, first for desc), so an explicit default and an
    # omitted one make equal candidates. Strings work too, in any case.
    IndexCandidate::KeyColumn = Data.define(:name, :direction, :nulls) do
      def initialize(name:, direction: :asc, nulls: nil)
        unless name.is_a?(String) && !name.empty?
          raise ArgumentError, "column name must be a non-empty String, got #{name.inspect}"
        end

        direction = pick(:direction, direction, %i[asc desc])
        nulls = pick(:nulls, nulls || IndexCandidate::KeyColumn::DEFAULT_NULLS.fetch(direction), %i[first last])
        super(name: name.dup.freeze, direction:, nulls:)
      end

      # Ascending, with nulls last: what Postgres does when a key column
      # says nothing.
      def default_order? = direction == :asc && nulls == :last

      private

      def pick(what, value, allowed)
        choice = value.to_s.downcase.to_sym
        return choice if allowed.include?(choice)

        raise ArgumentError, "#{what} must be one of #{allowed.inspect}, got #{value.inspect}"
      end
    end

    IndexCandidate::KeyColumn::DEFAULT_NULLS = { asc: :last, desc: :first }.freeze
  end
end
