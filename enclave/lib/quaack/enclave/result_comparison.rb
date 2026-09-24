# frozen_string_literal: true

require "pg_query"
require_relative "result_comparator"
require_relative "supported_sql"

module Quaack
  module Enclave
    # Step 9d's query shaping, reused by 10b and 14c. It reads the original
    # query with pg_query to pick the comparison mode, builds the queries
    # to run, runs them in an ArenaRunner transaction, and hands the results
    # to ResultComparator (result_comparator.rb).
    #
    #   runner.with_fixture(rows) do |tx|
    #     ResultComparison.compare(tx, original:, candidate:)
    #   end
    #
    # Only the top level of the original counts. The mode, by its ORDER BY
    # and LIMIT:
    #
    # - No ORDER BY and no LIMIT or OFFSET: multiset. Run both as written.
    # - ORDER BY: ordered. Its keys might not order rows fully, so append a
    #   tiebreaker of output positions to both queries, ORDER BY <keys>, 1,
    #   2, ..., n, and keep the LIMIT and OFFSET. The tiebreaker needs the
    #   output types first, so a probe runs each query wrapped with LIMIT 0
    #   and compares their columns. If they differ, that's the verdict, and
    #   nothing else runs.
    #
    #   The tiebreaker goes on the candidate too, so it could supply an
    #   order the candidate never asked for: a candidate that drops a sort
    #   key, or whose keys tie everything, would come out in the original's
    #   order by luck. So each query runs twice: with the tiebreaker
    #   ascending (T), and with every tiebreaker position DESC NULLS FIRST
    #   (T', the exact reverse). The candidate's T run must match the
    #   original's T run, row for row, and likewise for T'.
    #
    #   First, though, the original's T and T' runs must hold the same
    #   multiset of rows, or it's an unsupported_order mismatch and the
    #   candidate never runs. They differ when a LIMIT or OFFSET cuts a tie
    #   group, or a DISTINCT ON picks from one, and the rows on either side
    #   of the cut differ. Then the original's answer depends on how the tie
    #   breaks, and two runs can't check a candidate: T and T' only show the
    #   first and last rows of a tie in T order, so a candidate could widen
    #   the tie at the cut with a row between those and match both runs.
    #
    #   When the multisets are equal, the two runs are sound. With no cut
    #   the original's rows are fixed. With a cut, each tie group the cut
    #   passes through gives the same rows in T and T', and a group's rows
    #   sorted in T order can only do that if they're all equal on every
    #   tiebreaker column. So the original's answer doesn't depend on how
    #   its ties break. A candidate matching both runs has the same rows
    #   before the cut, in order. Any rows it ties with the ones at the cut
    #   come out first in T and last in T', and both runs show the
    #   original's rows there, so those rows are equal to the original's on
    #   every tiebreaker column too. Two rows the original orders but the
    #   candidate leaves tied stay put in the original and swap places in
    #   the candidate between the runs, so one run mismatches.
    # - LIMIT or OFFSET with no ORDER BY: subset. Any rows are a valid
    #   answer. Run the original as written for the expected row count,
    #   which Postgres works out whatever the LIMIT expression is. Run it
    #   again without its LIMIT and OFFSET for the full result. The
    #   candidate's rows must be a sub-multiset of the full result, with
    #   that count. FETCH FIRST ... ONLY is a LIMIT.
    # - FETCH FIRST ... WITH TIES: with_ties, an unsupported_order mismatch
    #   with nothing run. A tiebreaker would change which rows come back,
    #   and without one the order of tied rows can't be checked, so the
    #   comparison fails closed and never says match.
    #
    # When the original has an ORDER BY and the candidate has none at its
    # top level, that's a candidate_unordered mismatch, with nothing run.
    #
    # The tiebreaker leaves out any column btree can't order, such as json,
    # xml, or point, since ORDER BY on one is an error, and one error ends
    # the arena transaction. It keeps the built-in types in ORDERABLE_TYPES,
    # plus the enums, ranges, and composites of orderable fields that the
    # catalog lookup finds (CATALOG_ORDERABLE_SQL). A domain reports its
    # base type, so it's covered by that type. Anything else, such as
    # extension types, nested composites, and composites with a json
    # field, is left out. That leaves a window both ways. Rows that tie on
    # every column the tiebreaker has, and differ only in one it left out,
    # don't swap between the two runs. So a candidate that leaves such rows
    # tied where the original orders them can still match, and a good
    # candidate can mismatch when those rows come back in either order.
    #
    # DISTINCT, DISTINCT ON, and set operations (UNION, INTERSECT, EXCEPT)
    # need nothing more. Their top-level ORDER BY and LIMIT are read the
    # same way. Known ways to discard a good candidate, all toward
    # mismatch:
    #
    # - A LIMIT inside a subquery, or DISTINCT ON with no ORDER BY, picks
    #   rows Postgres is free to vary.
    # - A candidate whose ORDER BY adds its own keys, such as ORDER BY a, id
    #   for ORDER BY a, orders ties its own way before the tiebreaker.
    # - Floats within tolerance of each other can sort either way in the
    #   tiebreaker.
    #
    # Trust boundary. The verdict is ResultComparator's, with counts and
    # positions only. The built SQL keeps the query's literals, so it stays
    # in the enclave. A parse error becomes an Error with a fixed message
    # and no cause, since pg_query's message quotes the SQL. Both queries
    # go through SupportedSql.check! too, like every walker's input, so a
    # construct the enclave doesn't support is refused by its node type.
    # Errors from running a query are ArenaRunner::Errors, which keep no
    # Postgres text.
    module ResultComparison
      class Error < StandardError
        # query is :original or :candidate.
        attr_reader :rule, :query

        def initialize(rule, query:)
          @rule = rule
          @query = query
          super(RULES.fetch(rule))
        end
      end

      RULES = {
        unparsable: "a query for the result comparison couldn't be parsed",
        not_one_select: "a query for the result comparison isn't exactly one SELECT"
      }.freeze

      # Built-in types that ORDER BY can sort, and their arrays, as [oid,
      # array oid]. result_comparison_postgres_spec.rb checks each one
      # against Postgres.
      ORDERABLE_TYPES = {
        bool: [16, 1000], bytea: [17, 1001], char: [18, 1002], name: [19, 1003], int8: [20, 1016],
        int2: [21, 1005], int4: [23, 1007], text: [25, 1009], oid: [26, 1028], tid: [27, 1010],
        float4: [700, 1021], float8: [701, 1022], money: [790, 791], macaddr8: [774, 775],
        macaddr: [829, 1040], cidr: [650, 651], inet: [869, 1041], bpchar: [1042, 1014],
        varchar: [1043, 1015], date: [1082, 1182], time: [1083, 1183], timestamp: [1114, 1115],
        timestamptz: [1184, 1185], interval: [1186, 1187], timetz: [1266, 1270], bit: [1560, 1561],
        varbit: [1562, 1563], numeric: [1700, 1231], uuid: [2950, 2951], pg_lsn: [3220, 3221],
        tsvector: [3614, 3643], tsquery: [3615, 3645], jsonb: [3802, 3807]
      }.freeze
      ORDERABLE_OIDS = ORDERABLE_TYPES.values.flatten.to_set.freeze

      # Which of the result's other types (%<types>s) ORDER BY can sort,
      # from the catalog: enums, ranges, arrays of either, and composites
      # whose fields are all ORDERABLE_OIDS (%<known>s), enums, or ranges.
      # Postgres sorts those through its polymorphic btree operator
      # classes. A domain needs nothing here, since a result reports its
      # base type. A composite with any other field, such as json, another
      # composite, or a domain, is left out, and so is an array of one.
      CATALOG_ORDERABLE_SQL = <<~SQL
        SELECT t.oid::int
        FROM pg_type t
        LEFT JOIN pg_type e ON e.oid = t.typelem AND t.typsubscript = 'array_subscript_handler'::regproc
        WHERE t.oid IN (%<types>s)
          AND (t.typtype IN ('e', 'r') OR e.typtype IN ('e', 'r')
            OR (t.typtype = 'c' AND NOT EXISTS (
              SELECT FROM pg_attribute a JOIN pg_type f ON f.oid = a.atttypid
              WHERE a.attrelid = t.typrelid AND a.attnum > 0 AND NOT a.attisdropped
                AND NOT (f.oid IN (%<known>s) OR f.typtype IN ('e', 'r')))))
      SQL

      # One query's top level, parsed. Each builder parses the SQL again, so
      # none changes another's tree.
      class Shape
        def self.parse(sql, query)
          new(sql, query)
        end

        def initialize(sql, query)
          @sql = sql
          @query = query
          parsed = parse
          select_stmt(parsed)
          SupportedSql.check!(parsed)
        end

        def mode
          select = select_stmt(parse)
          return :with_ties if select.limit_option == :LIMIT_OPTION_WITH_TIES
          return :ordered unless select.sort_clause.empty?

          select.limit_count || select.limit_offset ? :subset : :multiset
        end

        def ordered? = !select_stmt(parse).sort_clause.empty?

        def without_limit
          build do |select|
            select.limit_count = nil
            select.limit_offset = nil
          end
        end

        # positions are 1-based output column positions. descending sorts
        # each DESC NULLS FIRST, the exact reverse of the default.
        def with_tiebreaker(positions, descending: false)
          build do |select|
            positions.each { |position| select.sort_clause << position_sort(position, descending) }
          end
        end

        def probe = "SELECT * FROM (#{build { nil }}) quaack_probe LIMIT 0"

        private

        def parse
          PgQuery.parse(@sql)
        rescue PgQuery::ParseError
          raise Error.new(:unparsable, query: @query), cause: nil
        end

        def select_stmt(parsed)
          statements = parsed.tree.stmts
          select = statements.first.stmt.select_stmt if statements.size == 1
          raise Error.new(:not_one_select, query: @query), cause: nil unless select

          select
        end

        def build
          parsed = parse
          yield select_stmt(parsed)
          PgQuery.deparse(parsed.tree)
        end

        def position_sort(position, descending)
          constant = PgQuery::Node.new(a_const: PgQuery::A_Const.new(ival: PgQuery::Integer.new(ival: position)))
          direction, nulls = descending ? %i[SORTBY_DESC SORTBY_NULLS_FIRST] : %i[SORTBY_DEFAULT SORTBY_NULLS_DEFAULT]
          PgQuery::Node.new(sort_by: PgQuery::SortBy.new(node: constant, sortby_dir: direction, sortby_nulls: nulls))
        end
      end

      module_function

      # Runs the original and the candidate in transaction, an
      # ArenaRunner::Transaction, and returns a ResultComparator::Verdict.
      def compare(transaction, original:, candidate:)
        original_shape = Shape.parse(original, :original)
        candidate_shape = Shape.parse(candidate, :candidate)
        mode = original_shape.mode
        return run(transaction, original, candidate, mode) if mode == :multiset
        return subset(transaction, original_shape, original, candidate) if mode == :subset
        return ResultComparator::Verdict.for(mode, :unsupported_order) if mode == :with_ties
        return ResultComparator::Verdict.for(mode, :candidate_unordered) unless candidate_shape.ordered?

        ordered(transaction, original_shape, candidate_shape)
      end

      def run(transaction, original, candidate, mode)
        ResultComparator.compare(transaction.query(original), transaction.query(candidate), mode:)
      end

      def subset(transaction, original_shape, original, candidate)
        expected_count = transaction.query(original).rows.size
        full = transaction.query(original_shape.without_limit)
        ResultComparator.compare(full, transaction.query(candidate), mode: :subset, expected_count:)
      end

      def ordered(transaction, original_shape, candidate_shape)
        original_probe = transaction.query(original_shape.probe)
        shape = ResultComparator.shape_mismatch(original_probe, transaction.query(candidate_shape.probe), :ordered, {})
        return shape if shape

        positions = tiebreaker_positions(original_probe.types, catalog_orderable(transaction, original_probe.types))
        originals = [false, true].map do |descending|
          transaction.query(original_shape.with_tiebreaker(positions, descending:))
        end
        return ResultComparator::Verdict.for(:ordered, :unsupported_order) unless ties_uncut?(*originals)

        tiebroken(transaction, originals, candidate_shape, positions)
      end

      # Whether the original returns the same rows whichever way its ties
      # break, as far as the two tiebreaker runs show.
      def ties_uncut?(ascending, descending)
        ResultComparator.compare(ascending, descending, mode: :multiset).match?
      end

      def tiebroken(transaction, originals, candidate_shape, positions)
        verdict = nil
        originals.zip([false, true]).each do |original, descending|
          candidate = transaction.query(candidate_shape.with_tiebreaker(positions, descending:))
          verdict = ResultComparator.compare(original, candidate, mode: :ordered)
          return verdict unless verdict.match?
        end
        verdict
      end

      # The type OIDs among types, beyond ORDERABLE_OIDS, that the catalog
      # says ORDER BY can sort (see CATALOG_ORDERABLE_SQL). None are looked
      # up when every type is already known. types come from a Result's
      # ftype, so they're Integers and safe to put in the SQL.
      def catalog_orderable(transaction, types)
        unknown = types.reject { |oid| ORDERABLE_OIDS.include?(oid) }.uniq
        return [] if unknown.empty?

        sql = format(CATALOG_ORDERABLE_SQL, types: unknown.join(", "), known: ORDERABLE_OIDS.to_a.join(", "))
        transaction.query(sql).rows.map { |(oid)| Integer(oid) }
      end

      # The 1-based positions of the columns whose types are in
      # ORDERABLE_OIDS or catalog_orderable.
      def tiebreaker_positions(types, catalog_orderable = [])
        types.each_index.select { |i| ORDERABLE_OIDS.include?(types[i]) || catalog_orderable.include?(types[i]) }
             .map { |i| i + 1 }
      end
    end
  end
end
