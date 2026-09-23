# frozen_string_literal: true

require "pg_query"
require_relative "table_name"

module Quaack
  module Enclave
    # One proposed index, as the index generators emit it (README 5a-1, 5a-2,
    # and 5a-5) and as the filter and tests downstream consume it (5a-3, 5a-4).
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
    # name, which both Postgres and HypoPG allow. Construction checks the
    # shape cheaply. The predicate's SQL is only parsed by to_ddl.
    #
    # Equality and hash ignore sources, so two generators' copies of the same
    # definition collapse in a Set or a Hash. merge_sources combines them.
    # Nothing else is normalized: key order, INCLUDE order, and predicate text
    # all count.
    #
    # A candidate with a predicate is value-class data under the README's trust
    # boundary, because the predicate can hold a real literal. Only 5a-3's
    # low-cardinality check makes such a predicate safe to send out.
    IndexCandidate = Data.define(:table, :key, :include, :access_method, :predicate, :sources) do
      # One keyword per member, which is more than the cop allows.
      def initialize(table:, key:, sources:, include: [], access_method: :btree, predicate: nil) # rubocop:disable Metrics/ParameterLists
        raise ArgumentError, "table must be a schema-qualified TableName" unless table.is_a?(TableName)

        key = self.class.key_columns(key)
        super(table:, key:, include: self.class.include_columns(include, key),
              access_method: self.class.access_method(access_method),
              predicate: self.class.predicate(predicate),
              sources: sources.to_set(&:to_sym).freeze)
      end

      def self.include_columns(include, key)
        columns = include.map { |c| column_name(c) }.freeze
        both = key.map(&:name) & columns
        raise ArgumentError, "columns in both the key and INCLUDE: #{both.map(&:inspect).join(", ")}" if both.any?

        columns
      end

      def self.key_columns(key)
        columns = key.map { |k| k.is_a?(self::KeyColumn) ? k : self::KeyColumn.new(name: k) }.freeze
        raise ArgumentError, "key must have at least one column" if columns.empty?

        columns
      end

      def self.column_name(name)
        return name.dup.freeze if name.is_a?(String) && !name.empty?

        raise ArgumentError, "column name must be a non-empty String, got #{name.inspect}"
      end

      # Any plain identifier, so a method this doesn't know about still works.
      def self.access_method(method)
        name = method.to_s.downcase
        return name.to_sym if /\A[a-z_][a-z0-9_]*\z/.match?(name)

        raise ArgumentError, "index method must be a plain identifier, got #{method.inspect}"
      end

      def self.predicate(sql)
        return nil if sql.nil?
        return sql.dup.freeze if sql.is_a?(String) && !sql.strip.empty?

        raise ArgumentError, "predicate must be SQL text or nil, got #{sql.inspect}"
      end

      # Everything but sources.
      def definition = [table, key, include, access_method, predicate]

      def ==(other) = other.is_a?(IndexCandidate) && definition == other.definition

      def eql?(other) = other.is_a?(IndexCandidate) && definition.eql?(other.definition)

      def hash = [IndexCandidate, definition].hash

      # A copy of this candidate with the other's sources added. The other
      # must have the same definition.
      def merge_sources(other)
        raise ArgumentError, "can't merge sources from a different definition: #{other.inspect}" unless self == other

        with(sources: sources | other.sources)
      end

      # CREATE INDEX DDL, built as a pg_query parse tree and deparsed. Raises
      # ArgumentError if the predicate isn't a single SQL expression.
      def to_ddl
        PgQuery.deparse_stmt(
          PgQuery::IndexStmt.new(
            relation:,
            access_method: access_method.to_s,
            index_params: key.map { |k| PgQuery::Node.new(index_elem: k.index_elem) },
            index_including_params:,
            where_clause: predicate && self.class.parse_predicate(predicate)
          )
        )
      end

      # Parses the predicate as the WHERE clause of an otherwise empty SELECT,
      # and refuses it unless that SELECT has nothing but the WHERE clause.
      # That keeps a second statement, a UNION, or a stray ORDER BY out of
      # the DDL. The newline ends any trailing line comment.
      def self.parse_predicate(sql)
        stmts = PgQuery.parse("SELECT WHERE #{sql}\n").tree.stmts
        select = stmts.first.stmt.select_stmt if stmts.size == 1
        where = select&.where_clause
        return where if where && select == bare_select(where)

        raise ArgumentError, "predicate must be a single SQL expression: #{sql}"
      rescue PgQuery::ParseError => e
        raise ArgumentError, "predicate doesn't parse: #{e.message}"
      end

      def self.bare_select(where)
        PgQuery::SelectStmt.new(where_clause: where, limit_option: :LIMIT_OPTION_DEFAULT, op: :SETOP_NONE)
      end

      private

      def relation
        PgQuery::RangeVar.new(schemaname: table.schema, relname: table.name, inh: true, relpersistence: "p")
      end

      def index_including_params
        include.map { |c| PgQuery::Node.new(index_elem: PgQuery::IndexElem.new(name: c)) }
      end
    end

    # One column of an index key. direction is :asc or :desc. nulls is :first
    # or :last. When nulls is omitted, it takes Postgres's default for the
    # direction (last for asc, first for desc), so an explicit default and an
    # omitted one make equal candidates. Strings work too, in any case.
    IndexCandidate::KeyColumn = Data.define(:name, :direction, :nulls) do
      def initialize(name:, direction: :asc, nulls: nil)
        direction = self.class.pick(:direction, direction, %i[asc desc])
        nulls = self.class.pick(:nulls, nulls || self.class.default_nulls(direction), %i[first last])

        super(name: IndexCandidate.column_name(name), direction:, nulls:)
      end

      def self.pick(what, value, allowed)
        choice = value.to_s.downcase.to_sym
        return choice if allowed.include?(choice)

        raise ArgumentError, "#{what} must be one of #{allowed.inspect}, got #{value.inspect}"
      end

      def self.default_nulls(direction) = direction == :asc ? :last : :first

      # Leaves out whatever matches Postgres's defaults, so the DDL reads
      # the way a person would write it.
      def index_elem
        PgQuery::IndexElem.new(
          name:,
          ordering: direction == :desc ? :SORTBY_DESC : :SORTBY_DEFAULT,
          nulls_ordering: nulls_ordering
        )
      end

      private

      def nulls_ordering
        return :SORTBY_NULLS_DEFAULT if nulls == self.class.default_nulls(direction)

        nulls == :first ? :SORTBY_NULLS_FIRST : :SORTBY_NULLS_LAST
      end
    end
  end
end
