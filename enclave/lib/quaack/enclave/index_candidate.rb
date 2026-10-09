# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "table_name"
require_relative "index_sql"
require_relative "index_key_sql"
require_relative "index_methods"

module Quaack
  module Enclave
    # One proposed index, as the mechanical generators emit it (DESIGN.md's index-from-query
    # and index-from-plan) and as the filter and tests downstream consume it (index-dedupe,
    # index-test), and as llm-index-ideas reads the LLM's DDL. A key column can be an
    # expression, with an opclass and a collation (see KeyColumn).
    #
    #   IndexCandidate.new(
    #     table: TableName.new(schema: "public", name: "orders"),
    #     key: ["customer_id", IndexCandidate::KeyColumn.new(name: "created_at", direction: :desc)],
    #     include: ["total"],              # default []
    #     access_method: :btree,           # default :btree
    #     predicate: "status = 'open'",    # default nil
    #     unique: false,                   # default false
    #     sources: [:parse]                # the generators that proposed it
    #   ).to_ddl
    #   # => "CREATE INDEX ON public.orders USING btree (customer_id, created_at DESC)
    #   #     INCLUDE (total) WHERE status = 'open'"
    #
    # A bare String in key is an ascending column. Column and table names are
    # real catalog names, unquoted. to_ddl quotes them. The DDL has no index
    # name, which both Postgres and HypoPG allow.
    #
    # unique is for existing indexes, which from_ddl reads: primary keys,
    # UNIQUE constraints, and CREATE UNIQUE INDEX. The generators propose
    # plain indexes. A unique index and a plain one on the same columns are
    # different definitions, so index-dedupe compares key columns itself when it
    # checks whether an existing index covers a candidate. A deferrable
    # UNIQUE constraint also reads as unique: true, because pg_get_indexdef
    # prints it the same way. To propose a candidate built on an existing
    # index, as index-from-plan does when it extends the index in use, use
    # existing.with(key: ..., unique: false, sources: [...]). A plain
    # with(key: ...) on orders_pkey would keep unique: true and
    # sources: [:existing], so index-dedupe couldn't dedupe it against the other
    # generators' plain candidates.
    #
    # The constructor refuses what Postgres would refuse for the built-in
    # methods: a non-default direction or nulls ordering, or unique, on
    # anything but btree; INCLUDE on brin, gin, or hash; and more than one
    # key column on hash or spgist.
    #
    # The predicate is parsed at construction and stored as pg_query deparses
    # it, so "(status = 'open')" and "status = 'open'" make equal candidates.
    # Casts don't normalize away: "status::text = 'open'" stays different.
    # A predicate that pg_query deparses as SQL that doesn't parse back to the
    # same expression, even with Deparse::Parentheses, such as 't'::boolean, is
    # refused with Error, since stored that way it would mean
    # something else. from_ddl returns nil for one.
    # The constructor refuses a predicate with a parameter ($1), a subquery,
    # or an aggregate, window, or grouping call. It finds a plain call like
    # sum(b) by name, against the aggregates and window functions built into
    # Postgres 18, so a user-defined aggregate or window function called
    # without aggregate or window syntax gets through. It doesn't check function volatility (random(), now()),
    # because that needs the catalog. DESIGN.md's volatility does that.
    #
    # That name check is unqualified: an unqualified call to a user-defined
    # function that happens to share a built-in's name, such as lead(x) where
    # lead is a schema's own function rather than the window function, is
    # wrongly refused as if it were the built-in. Postgres itself accepts such
    # a function and such an index, and pg_get_indexdef can print the call
    # unqualified when the function's schema is first on search_path, so
    # from_ddl returns nil for an existing index built on one. This is rare
    # and harmless: the index just can't be represented as a candidate, the
    # same as any other DDL the constructor refuses.
    #
    # Equality and hash ignore sources, so two generators' copies of the same
    # definition collapse in a Set or a Hash. merge_sources combines them.
    # Key order and INCLUDE order both count.
    #
    # A candidate with a predicate is value-class data under DESIGN.md's trust
    # boundary, because the predicate can hold a real literal. So inspect,
    # to_s, pp, and every error message leave the predicate text out. Pattern
    # matching can't see the predicate at all: deconstruct_keys leaves it out
    # and there's no deconstruct, so a failed match can't quote it. Only
    # to_ddl, the predicate reader, and to_h give it back, and they return the
    # raw text, so keep what they return inside the enclave.
    IndexCandidate = Data.define(:table, :key, :include, :access_method, :predicate, :unique, :sources) do
      # One keyword per member, which is more than the cop allows.
      def initialize(table:, key:, sources:, include: [], access_method: :btree, predicate: nil, unique: false) # rubocop:disable Metrics/ParameterLists
        raise IndexCandidateError, "table must be a schema-qualified TableName" unless table.is_a?(TableName)

        key = key_columns(key)
        include = include_columns(include, key)
        access_method = normalize_access_method(access_method)
        IndexMethods.check(access_method, key:, include:, unique:)
        super(table:, key:, include:, access_method:, predicate: normalize_predicate(predicate), unique:,
              sources: sources.to_set(&:to_sym).freeze)
      end

      # Reads one CREATE INDEX, as pg_get_indexdef prints it, into a candidate
      # with the given sources. The index name is dropped: TableStatistics
      # keeps it as the key of its indexes map. Returns nil for an index this
      # shape can't represent: an opclass with parameters, NULLS
      # NOT DISTINCT, ON ONLY, WITH options, TABLESPACE, CONCURRENTLY, IF NOT
      # EXISTS, an unqualified table, or anything the constructor refuses.
      # For an existing index, use from_indexdef. Raises Error if the SQL isn't exactly one CREATE INDEX. No
      # error message includes the SQL.
      def self.from_ddl(sql, sources:) = IndexSql.read_index(sql, sources)

      # Reads an existing index, as pg_get_indexdef prints it, with sources
      # [:existing]. Like from_ddl, but it drops WITH (...) storage
      # parameters, such as fillfactor, and reads a NULLS NOT DISTINCT
      # unique index as plain unique: neither changes which queries the
      # index serves, so it still covers a candidate in index-dedupe. A
      # NULLS NOT DISTINCT index is a stricter unique than plain UNIQUE, so
      # as a uniqueness fact it only says less than is true. ON ONLY still
      # gives nil: Postgres prints it only for an index on a partitioned
      # table, and v1 refuses a query on one, so no run reads one.
      # from_ddl keeps refusing these, since it also reads the LLM's DDL,
      # where dropping an option would test something other than what was
      # proposed.
      #
      # types maps a column to its type's name (PlannerStatistics's
      # column_types). With it, the implicit text casts Postgres prints for a
      # varchar column's predicate are dropped (see ImplicitCast), so a
      # candidate written without them matches. With none, they stay.
      def self.from_indexdef(sql, types: {}) = IndexSql.read_index(sql, [:existing], existing: true, types:)

      # Pattern matching sees every member but the predicate, so a failed
      # match can't quote it. There's no positional (array) pattern.
      def deconstruct_keys(keys) = super.except(:predicate)

      undef_method :deconstruct

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
        raise IndexCandidateError, "can't merge sources from a different definition" unless self == other

        with(sources: sources | other.sources)
      end

      # CREATE INDEX DDL, built as a pg_query parse tree and deparsed. This is
      # the one output that holds the predicate's literals. HypoPG runs it, so
      # it must parse back to the tree that was built, or it raises
      # Deparse::Error. A name longer than Postgres allows would be cut short.
      def to_ddl
        Deparse.statement(
          PgQuery::IndexStmt.new(
            relation:, unique:,
            access_method: access_method.to_s,
            index_params:,
            index_including_params: include.map { |c| IndexKeySql.index_elem(IndexCandidate::KeyColumn.new(name: c)) },
            where_clause: predicate && IndexSql.parse_predicate(predicate)
          )
        )
      end

      protected

      # Everything but sources. Protected, so == can compare two candidates
      # without the raw predicate showing up as one more public reader.
      def definition = [table, key, include, access_method, predicate, unique]

      private

      def key_columns(key)
        columns = key.map { |k| k.is_a?(IndexCandidate::KeyColumn) ? k : IndexCandidate::KeyColumn.new(name: k) }.freeze
        raise IndexCandidateError, "key must have at least one column" if columns.empty?

        columns
      end

      def include_columns(include, key)
        columns = include.map { |c| IndexKeySql.column_name(c) }.freeze
        both = key.map(&:name) & columns
        raise IndexCandidateError, "columns in both the key and INCLUDE: #{both.map(&:inspect).join(", ")}" if both.any?

        columns
      end

      # Any plain identifier, so a method this doesn't know about still works.
      def normalize_access_method(method)
        name = method.to_s.downcase
        return name.to_sym if /\A[a-z_][a-z0-9_]*\z/.match?(name)

        raise IndexCandidateError, "index method must be a plain identifier, got #{method.inspect}"
      end

      def normalize_predicate(sql)
        return nil if sql.nil?
        raise IndexCandidateError, "predicate must be SQL text or nil" unless sql.is_a?(String)

        # No separate blankness check: IndexSql.normalize_predicate parses "" and
        # whitespace-only text as an empty WHERE clause, which pg_query refuses
        # as a syntax error, so it already raises Error on its own.
        IndexSql.normalize_predicate(sql)
      end

      def index_params = key.map { |k| IndexKeySql.index_elem(k) }

      def relation
        PgQuery::RangeVar.new(schemaname: table.schema, relname: table.name, inh: true, relpersistence: "p")
      end
    end

    # One column of an index key: a column name, or an expression such as
    # lower(email). direction is :asc or :desc. nulls is :first or :last.
    # When nulls is omitted, it takes Postgres's default for the direction
    # (last for asc, first for desc), so an explicit default and an omitted
    # one make equal candidates. Strings work too, in any case.
    #
    #   KeyColumn.new(expression: "lower(email)", opclass: "text_pattern_ops", collation: "C")
    #
    # An expression is parsed at construction and stored as pg_query
    # deparses it, so "LOWER( email )" and "(lower(email))" are equal. One
    # that's only a column, such as "(email)", becomes that column's name.
    # It's refused, with IndexCandidate::Error, unless it's one expression with no
    # parameter, subquery, or aggregate, window, or grouping call, as for a
    # predicate. Casts don't normalize away, and neither does anything else
    # Postgres would resolve with the catalog. Function volatility isn't
    # checked here. IndexDdlCheck checks it on the LLM's DDL.
    #
    # opclass and collation are qualified names, given as a String for an
    # unqualified name or an Array of name parts. A leading pg_catalog is
    # dropped, as pg_get_indexdef leaves it off for a built-in. They're
    # stored as frozen Arrays, or nil. An opclass with parameters, such as
    # gist_trgm_ops(siglen=32), isn't held. The shape can't tell a default
    # opclass or collation written out from one left off, since that needs
    # the catalog, so (email text_ops) and (email) are different key
    # columns. pg_get_indexdef leaves defaults off, so an existing index
    # reads as the plain column, and only a candidate that spells out a
    # default fails to match it. That only costs one more test in index-test.
    #
    # An expression can hold a literal, so it's value-class data, like a
    # predicate: inspect, to_s, pp, and pattern matching leave it out, and
    # no error message quotes it.
    IndexCandidate::KeyColumn = Data.define(:name, :expression, :direction, :nulls, :opclass, :collation) do
      # One keyword per member, which is more than the cop allows.
      def initialize(name: nil, expression: nil, direction: :asc, nulls: nil, opclass: nil, collation: nil) # rubocop:disable Metrics/ParameterLists
        name, expression = IndexKeySql.column_or_expression(name, expression)
        direction = pick(:direction, direction, %i[asc desc])
        nulls = pick(:nulls, nulls || IndexCandidate::KeyColumn::DEFAULT_NULLS.fetch(direction), %i[first last])
        super(name:, expression:, direction:, nulls:,
              opclass: IndexKeySql.qualified_name(:opclass, opclass),
              collation: IndexKeySql.qualified_name(:collation, collation))
      end

      # Ascending, with nulls last: what Postgres does when a key column
      # says nothing.
      def default_order? = direction == :asc && nulls == :last

      # Pattern matching sees every member but the expression.
      def deconstruct_keys(keys) = super.except(:expression)

      undef_method :deconstruct

      def inspect
        shown = to_h.map do |member, value|
          "#{member}=#{member == :expression && value ? "<redacted>" : value.inspect}"
        end
        "#<data #{self.class} #{shown.join(", ")}>"
      end

      alias_method :to_s, :inspect

      def pretty_print(pp) = pp.text(inspect)

      private

      def pick(what, value, allowed)
        choice = value.to_s.downcase.to_sym
        return choice if allowed.include?(choice)

        raise IndexCandidateError, "#{what} must be one of #{allowed.inspect}, got #{value.inspect}"
      end
    end

    IndexCandidate::KeyColumn::DEFAULT_NULLS = { asc: :last, desc: :first }.freeze
    IndexCandidate::Error = IndexCandidateError
  end
end
