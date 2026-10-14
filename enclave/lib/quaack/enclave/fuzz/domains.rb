# frozen_string_literal: true

require "pg"
require "pg_query"
require_relative "../predicate_atoms"
require_relative "../value_pools"
require_relative "dictionary"
require_relative "facts"
require_relative "key_classes"
require_relative "legal"
require_relative "thresholds"
require_relative "tree"
require_relative "typical"
require_relative "world_values"

module Quaack
  module Enclave
    module Fuzz
      # The values the search draws each footprint column's from.
      #
      # - A read column (one either query names) gets ValuePools' pools for
      #   the queries' atoms on it (their literals, one unit either side,
      #   case and LIKE variants, NULL, boundaries), and the queries'
      #   constants Dictionary: every constant in either query its type can
      #   read, whatever the column, and that constant's near neighbours.
      #   Atoms miss a column read through a CTE's or subquery's output, and
      #   the constant is still the value most likely to matter.
      # - Columns a join atom or a kept foreign key ties together are one
      #   key class (KeyClasses), and share their values and a small pool of
      #   keys (base_keys), so joins find partners.
      # - Every value must pass the column's own CHECKs (Legal). A CHECK's
      #   own constants are values too, the only ones a column it pins can
      #   take.
      #
      # - A read column also gets WorldValues' classes for its type: values
      #   from world knowledge, such as padded and case-folded strings, NaN,
      #   ISO-week dates, DST hours, and each JSON type for a key the queries
      #   read, each cast to the column's type, which must read it.
      #
      # Built, and each column the generator plans for prepared, before the
      # session's transaction, since the probes can't run in it. Trust
      # boundary: these are real values, so they stay in the enclave.
      class Domains # rubocop:disable Metrics/ClassLength -- every pool a column draws from
        NUMERIC_KEY = /\A(smallint|integer|bigint|numeric)/
        KEYS = 40
        CHECK_CONSTANTS = 4

        def initialize(conn, catalog, sqls)
          @conn = conn
          @catalog = catalog
          @values = Hash.new { |h, k| h[k] = [] }
          @classes = KeyClasses.new
          @read = Set.new
          @compared = Set.new
          @legal = Legal.new(conn, catalog)
          @memo = {}
          absorb_all(sqls.map { PgQuery.parse(it) })
        end

        def read?(table, column) = @read.include?([table, column])

        def key?(table, column) = @classes.member?([table, column])

        # Whether a query tests the column against constants: a pooled atom
        # (ValuePools), such as id > 100 or a keyset's leading column.
        def compared?(table, column) = @compared.include?([table, column])

        # Works out everything the generator may ask of a column now, since
        # its probes can't run in the session's transaction, which a failed
        # world leaves aborted until the next trial rolls it back.
        def prepare(table, column)
          %i[typical boundaries base_keys class_values world].each { public_send(it, table, column) }
          unique(table, column, 0)
        end

        # A read column's values, with nil for NULL.
        def values(table, column) = @values.fetch([table, column], [])

        # The non-NULL values of every column in the column's key class.
        def class_values(table, column)
          memo(:class, table, column) do
            @classes.members([table, column]).flat_map { @values.fetch(it, []).compact }.uniq
          end
        end

        # Ordinary values that pass the column's CHECKs, else its CHECKs'
        # own constants.
        def typical(table, column)
          memo(:typical, table, column) do
            col = @catalog.column(table, column)
            typical = Typical.values(col.type, labels(col)).select { @legal.call(table, column, it) }
            typical.empty? ? @legal.constants(table, column).first(2) : typical
          end
        end

        # A read column's values from world knowledge (WorldValues), as its
        # type writes them, that pass its CHECKs.
        def world(table, column)
          memo(:world, table, column) do
            next [] unless read?(table, column)

            col = @catalog.column(table, column)
            @world.values(col.type, column, typical(table, column)).filter_map { cast(col.type, it) }.uniq
                  .select { @legal.call(table, column, it) }
          end
        end

        # How many copies of a row a world may hold (WorldValues#copies).
        def copies = @world.copies

        # Whether a query groups or partitions on the column's name.
        def grouped?(_table, column) = @world.grouped?(column)

        def boundaries(table, column)
          memo(:boundaries, table, column) do
            ValuePools.boundaries(@catalog.column(table, column).type).select { @legal.call(table, column, it) }
          end
        end

        # The nth distinct value for a column in a unique key, or nil. A
        # column a CHECK pins cycles through the CHECK's own constants.
        def unique(table, column, nth)
          constants = @legal.pinned?(table, column) ? @legal.constants(table, column) : []
          return constants[nth % constants.size] unless constants.empty?

          Typical.unique(@catalog.column(table, column).type, nth)
        end

        # The shared small keys for a key column, in its own type: 1, 2, 3
        # ... for numbers, the type's typical values then fresh ones
        # otherwise.
        def base_keys(table, column)
          memo(:base_keys, table, column) do
            keys = if @catalog.column(table, column).type.delete_prefix("pg_catalog.").match?(NUMERIC_KEY)
                     (1..KEYS).map(&:to_s)
                   else
                     typical(table, column) + (1..KEYS).map { unique(table, column, it) }
                   end
            keys.compact.uniq.select { @legal.call(table, column, it) }
          end
        end

        private

        def memo(*key) = @memo.fetch(key) { @memo[key] = yield }

        def cast(type, value)
          @conn.exec_params("SELECT CAST($1 AS #{type})::pg_catalog.text", [value]).getvalue(0, 0)
        rescue PG::Error
          nil
        end

        def absorb_all(parses)
          parses.each { absorb(it) }
          knowledge(parses.map { it.tree.to_h })
          @read.each do |table, column|
            @values[[table, column]] |= @dictionary.values(@catalog.column(table, column))
            solved(table, column)
          end
          @classes.join_foreign_keys(@catalog.kept)
          legalize
        end

        def knowledge(trees)
          @dictionary = Dictionary.new(@conn, trees.flat_map { Tree.constants(it) }.uniq)
          facts = Facts.new(trees)
          @world = WorldValues.new(@conn, facts)
          @thresholds = Thresholds.new(@conn, facts)
        end

        # A column's Thresholds and their neighbours, as its type writes
        # them, right after its first value, so they're among the first
        # classes enumerate takes. Legalize then drops those its CHECKs
        # forbid.
        def solved(table, column)
          solutions = @thresholds.values(table, column)
          return if solutions.empty?

          derived = typed(@catalog.column(table, column), solutions)
          values = @values[[table, column]]
          cut = (values.index { !it.nil? } || 0) + 1
          @values[[table, column]] = (values.take(cut) + derived + values.drop(cut)).uniq
        end

        # numbers and their neighbours, as col's type writes them.
        def typed(col, numbers) = Dictionary.new(@conn, numbers).values(col).filter_map { cast(col.type, it) }.uniq

        # A query's reads, join classes, and pools. Pools are extra values,
        # so a query whose atoms can't be read gives none, and still its
        # reads.
        def absorb(parse)
          reads(parse.tree.to_h)
          atoms = PredicateAtoms.extract(parse, column_names: @catalog.schema.column_names)
          atoms.select { it.kind == :join }.each { join(it) }
          ValuePools.build(@conn, parse, atoms, @catalog.schema).each_value { pooled(it) }
        rescue PredicateAtoms::Error, KeyError, PG::Error
          nil
        end

        def join(atom)
          atom.columns.select(&:table).map { [it.table, it.name] }.each_cons(2) { |a, b| @classes.join(a, b) }
        end

        def pooled(pool)
          column = [pool.column.table, pool.column.name]
          @compared << column
          extra = pool.nullable ? [nil] : []
          @values[column] |= pool.satisfying + pool.failing + pool.boundaries + extra
        end

        # Which footprint columns the query names. A star reads every
        # column of every footprint table, and so does a single name no
        # footprint table has, which may be a whole-row reference
        # (count(t), row_to_json(t)).
        def reads(node)
          Tree.references(node).each do |name, bare|
            hits = name == :star ? [] : @catalog.footprint.select { names(it).include?(name) }
            next hits.each { @read << [it, name] } unless hits.empty? && (name == :star || bare)

            @catalog.footprint.each { |table| names(table).each { @read << [table, it] } }
          end
        end

        def names(table) = memo(:names, table) { @catalog.columns(table).map(&:name) }

        def labels(col)
          memo(:labels, col.oid) { @dictionary.category(col) == "E" ? ValuePools::Category.labels(@conn, col) : nil }
        end

        # Drops the values a column's CHECKs forbid, and adds a few of the
        # CHECKs' own constants.
        def legalize
          @values.each_key.to_a.each do |table, column|
            next unless @legal.pinned?(table, column)

            kept = @values[[table, column]].select { it.nil? || @legal.call(table, column, it) }
            @values[[table, column]] = (kept + @legal.constants(table, column).first(CHECK_CONSTANTS)).uniq
          end
        end
      end
    end
  end
end
