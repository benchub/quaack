# frozen_string_literal: true

require "pg_query"
require_relative "deparse"
require_relative "result_comparator"
require_relative "supported_sql"
require_relative "result_comparison/tiebreaker"
require_relative "result_comparison/load_orders"
require_relative "result_comparison/cut_ties"

module Quaack
  module Enclave
    # fixture-compare's query shaping, reused by counterexample-compare and result-comparison. It reads the original
    # query with pg_query to pick the comparison mode, builds the queries
    # to run, runs them in an ArenaRunner transaction, and hands the results
    # to ResultComparator (result_comparator.rb).
    #
    #   runner.with_fixture(rows) do |tx|
    #     ResultComparison.compare(tx, original:, candidate:)
    #   end
    #
    # rewrite-test calls compare_in_both_orders (result_comparison/load_orders.rb)
    # instead, which runs compare twice, with the fixture loaded forward and
    # then in reverse, and matches only if both runs match. That covers much
    # of the first gap below.
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
    #   That holds only when the original's T and T' runs hold the same
    #   multiset of rows. They differ when a LIMIT or OFFSET cuts a tie
    #   group, or a DISTINCT ON picks from one, and the rows on either side
    #   of the cut differ. Then the original's answer depends on how the tie
    #   breaks, and T and T' only show the first and last rows of the tie
    #   in T order, so a candidate could widen the tie at the cut with a
    #   row between those and match both runs. A LIMIT with an OFFSET can
    #   also keep rows from the middle of a tie group, with rows of the
    #   group cut off on both sides, and then T and T' keep the same rows
    #   anyway, unless the original's runs through the end of the window
    #   (Shape#through_window) show no tie group crosses its edges. In both
    #   cases CutTies (result_comparison/cut_ties.rb) checks the candidate
    #   instead: it runs both queries both ways without their
    #   LIMIT and OFFSET to find the tie groups, and the candidate's rows
    #   before the cut's group must be the original's, in order, and the
    #   rest must come from that group, however either query's ties break.
    #   It refuses DISTINCT ON in either query, an OFFSET it can't place,
    #   and a candidate whose own tie at the cut could keep a row the
    #   original's group doesn't hold.
    #
    #   The principle. A column goes in the tiebreaker only if values btree
    #   calls equal are always equal to the comparator too (see Tiebreaker::UNFAITHFUL).
    #   Then rows the tiebreaker leaves tied look the same to the
    #   comparator, on every tiebreaker column.
    #
    #   When every output column is in the tiebreaker and the original's T
    #   and T' multisets are equal, with no LIMIT and OFFSET together, the
    #   two runs are sound. With no cut the original's rows are fixed. With
    #   a cut at one end of the rows kept, each tie group the cut
    #   passes through gives the same rows in T and T', and a group's rows
    #   sorted in T order can only do that if they're all btree-equal on
    #   every tiebreaker column, so equal to the comparator. So the
    #   original's answer doesn't depend on how its ties break. A candidate
    #   matching both runs has the same rows before the cut, in order. Any
    #   rows it ties with the ones at the cut come out first in T and last
    #   in T', and both runs show the original's rows there, so those rows
    #   are equal to the original's too. Two rows the original orders but
    #   the candidate leaves tied stay put in the original and swap places
    #   in the candidate between the runs, so one run mismatches, unless
    #   the comparator can't tell them apart anyway.
    #
    #   When some output column is left out of the tiebreaker, rows equal on
    #   every other column can't be split, and can differ in that column.
    #   So it's unsupported_order when:
    #   - the original or the candidate has a cut at its top level (a
    #     LIMIT, an OFFSET, DISTINCT, DISTINCT ON, or a set operation
    #     without ALL), since the cut can keep either of those rows, or
    #   - the original's T run has two rows equal on every tiebreaker
    #     column that differ in a left-out one, since they can come back in
    #     either order.
    #   Otherwise a left-out column's value follows from the tiebreaker
    #   columns in the original's rows, and the argument above holds.
    #
    #   A nondeterministic collation breaks the principle for text, and a
    #   result can't say which columns use one. So it's unsupported_order
    #   whenever a column, domain, or range type in the database uses one, or a COLLATE
    #   clause in either query names one.
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
    # The tiebreaker also leaves out any column btree can't order, such as
    # json, xml, or point, since ORDER BY on one is an error, and one error
    # ends the arena transaction. It keeps the built-in types in
    # Tiebreaker::TIEBREAKER_OIDS, plus the enums, ranges, arrays, and composites the
    # catalog lookup finds (CATALOG_ORDERABLE_SQL). A domain reports its
    # base type, so it's covered by that type.
    #
    # Gaps that remain in one compare, where a bad candidate can still
    # match:
    # - Nondeterminism below the top level. A LIMIT, DISTINCT, GROUP BY, or
    #   UNION inside a subquery or CTE, in either query, can keep any of
    #   several rows, or any representative of values btree calls equal,
    #   such as {"a": 1.0} for {"a": 1.00} in jsonb. So can a top-level DISTINCT or
    #   GROUP BY over such a column in a query with no ORDER BY. The fixture
    #   shows only the one Postgres picked.
    # - A nondeterministic collation outside the ordered mode, where no
    #   tiebreaker runs but a DISTINCT or GROUP BY can still pick either
    #   of 'a' and 'A'.
    # The reverse load in compare_in_both_orders catches both when the
    # pick follows the order rows reach it in, as a small sort or a first
    # row kept does. It can't when the pick follows something else that
    # comes out the same both ways, such as a hash table's order. It turns
    # index scans off so an index's order can't be that.
    #
    # Known ways to discard a good candidate, all toward mismatch:
    #
    # - A LIMIT inside a subquery, or DISTINCT ON with no ORDER BY, picks
    #   rows Postgres is free to vary.
    # - Every unsupported_order refusal above.
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
        not_one_select: "a query for the result comparison isn't exactly one SELECT",
        deparse_mismatch: "pg_query's deparser would change a query for the result comparison"
      }.freeze

      # One query's top level, parsed. Each builder parses the SQL again, so
      # none changes another's tree.
      #
      # rewrite-test compares the same two queries on every fixture, and
      # deparsing them is costly, so parse keeps each Shape it makes, and a
      # Shape keeps each answer and query it builds. Only answers are kept:
      # one that raises runs again the next time it's asked for.
      class Shape
        # How many Shapes parse keeps. A new one past this makes it forget
        # them all, so a long run can't grow it without bound.
        KEPT = 64

        @kept = {}

        private_class_method :new

        def self.parse(sql, query)
          sql = sql.dup.freeze unless sql.frozen?
          @kept.fetch([sql, query]) do |key|
            @kept.clear if @kept.size >= KEPT
            @kept[key] = new(sql, query)
          end
        end

        # Drops every Shape parse kept.
        def self.forget = @kept.clear

        def initialize(sql, query)
          @sql = sql
          @query = query
          @answers = {}
          parsed = parse
          select_stmt(parsed)
          SupportedSql.check!(parsed)
        end

        def mode
          kept(:mode) do
            select = select_stmt(parse)
            next :with_ties if select.limit_option == :LIMIT_OPTION_WITH_TIES
            next :ordered unless select.sort_clause.empty?

            select.limit_count || select.limit_offset ? :subset : :multiset
          end
        end

        def ordered? = kept(:ordered?) { !select_stmt(parse).sort_clause.empty? }

        # Whether the top level keeps only some of its rows: a LIMIT, an
        # OFFSET, DISTINCT or DISTINCT ON, or a UNION, INTERSECT, or EXCEPT
        # without ALL. Each can keep either of two rows btree calls equal.
        def cut?
          kept(:cut?) do
            select = select_stmt(parse)
            set_dedup = select.op != :SETOP_NONE && !select.all
            !!(select.limit_count || select.limit_offset || !select.distinct_clause.empty? || set_dedup)
          end
        end

        # Whether the top level has DISTINCT ON, which picks one row from
        # each tie group.
        def distinct_on? = kept(:distinct_on?) { select_stmt(parse).distinct_clause.any?(&:node) }

        # The top level's OFFSET when it's an integer constant, 0 when
        # there's none, and nil otherwise, such as for a parameter.
        def offset = kept(:offset) { ResultComparison.offset_value(select_stmt(parse).limit_offset) }

        # Whether the top level has a LIMIT and an OFFSET that might not be
        # 0, so the rows it keeps can sit inside a tie group with rows of
        # the group cut off on both sides.
        def cut_both_ends? = kept(:cut_both_ends?) { !select_stmt(parse).limit_count.nil? && offset != 0 }

        # The collation each COLLATE clause names, anywhere in the query,
        # without its schema.
        def collation_names = kept(:collation_names) { collations(parse.tree.to_h).freeze }

        def without_limit
          kept(:without_limit) do
            build { |select| unlimit(select) }
          end
        end

        # positions are 1-based output column positions. descending sorts
        # each DESC NULLS FIRST, the exact reverse of the default. Unless
        # limited, it drops the LIMIT and OFFSET too. limited :through adds
        # the OFFSET to the LIMIT instead, and drops the OFFSET.
        def with_tiebreaker(positions, descending: false, limited: true)
          kept([:with_tiebreaker, positions.dup.freeze, descending, limited]) do
            build do |select|
              positions.each { |position| select.sort_clause << position_sort(position, descending) }
              unlimit(select) unless limited
              ResultComparison.through_offset!(select) if limited == :through
            end
          end
        end

        # with_tiebreaker, with a LIMIT of the LIMIT and the OFFSET added
        # together, and no OFFSET: the rows up to the end of the ones kept.
        def through_window(positions, descending: false) = with_tiebreaker(positions, descending:, limited: :through)

        def probe = kept(:probe) { "SELECT * FROM (#{build { nil }}) quaack_probe LIMIT 0" }

        private

        def kept(key)
          @answers.fetch(key) { @answers[key] = yield }
        end

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
          Deparse.faithfully(parsed.tree)
        rescue Deparse::Error
          raise Error.new(:deparse_mismatch, query: @query), cause: nil
        end

        def unlimit(select)
          select.limit_count = nil
          select.limit_offset = nil
          # So the tree matches the one its SQL parses to, for the guard.
          select.limit_option = :LIMIT_OPTION_DEFAULT
        end

        def collations(node)
          case node
          when Hash
            own = node[:collate_clause] ? [node[:collate_clause][:collname].last[:string][:sval]] : []
            own + node.values.flat_map { |value| collations(value) }
          when Array then node.flat_map { |value| collations(value) }
          else []
          end
        end

        def position_sort(position, descending)
          constant = PgQuery::Node.new(a_const: PgQuery::A_Const.new(ival: PgQuery::Integer.new(ival: position)))
          direction, nulls = descending ? %i[SORTBY_DESC SORTBY_NULLS_FIRST] : %i[SORTBY_DEFAULT SORTBY_NULLS_DEFAULT]
          PgQuery::Node.new(sort_by: PgQuery::SortBy.new(node: constant, sortby_dir: direction, sortby_nulls: nulls))
        end
      end

      module_function

      # An OFFSET node's value when it's an integer constant, 0 for no
      # node, and nil otherwise.
      def offset_value(node)
        return 0 unless node

        node.a_const.ival.ival if node.node == :a_const && node.a_const.val == :ival
      end

      # Adds a SelectStmt's OFFSET to its LIMIT, and drops the OFFSET.
      def through_offset!(select)
        select.limit_count = sum(select.limit_count, select.limit_offset)
        select.limit_offset = nil
      end

      # The expression node left::bigint + right::bigint.
      def sum(left, right)
        plus = PgQuery::Node.new(string: PgQuery::String.new(sval: "+"))
        PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind: :AEXPR_OP, name: [plus], lexpr: bigint(left),
                                                      rexpr: bigint(right)))
      end

      def bigint(node)
        names = %w[pg_catalog int8].map { PgQuery::Node.new(string: PgQuery::String.new(sval: it)) }
        type_name = PgQuery::TypeName.new(names:, typemod: -1)
        PgQuery::Node.new(type_cast: PgQuery::TypeCast.new(arg: node, type_name:))
      end

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

        positions = checked_positions(transaction, original_shape, candidate_shape, original_probe.types)
        return refused unless positions

        originals = both_ways(transaction, original_shape, positions)
        return refused unless ties_faithful?(originals.first, positions)

        cut_tie(transaction, originals, [original_shape, candidate_shape], positions) ||
          tiebroken(transaction, originals, candidate_shape, positions)
      end

      def cut_tie?(transaction, shape, originals, positions)
        CutTies.needed?(shape, uncut: ties_uncut?(*originals), kept_rows: originals.first.rows.any?) do
          ties_uncut?(*[false, true].map { transaction.query(shape.through_window(positions, descending: it)) })
        end
      end

      def both_ways(transaction, shape, positions, limited: true)
        [false, true].map { |descending| transaction.query(shape.with_tiebreaker(positions, descending:, limited:)) }
      end

      def refused = ResultComparator::Verdict.for(:ordered, :unsupported_order)

      # The tiebreaker positions, or nil when the comparison must refuse
      # before running anything more: a nondeterministic collation, or a
      # column left out of the tiebreaker in a query with a cut.
      def checked_positions(transaction, original_shape, candidate_shape, types)
        shapes = [original_shape, candidate_shape]
        return if Tiebreaker.nondeterministic_collation?(transaction, shapes.flat_map(&:collation_names))

        positions = Tiebreaker.positions(types, Tiebreaker.catalog_orderable(transaction, types))
        positions if positions.size == types.size || shapes.none?(&:cut?)
      end

      # Whether rows the tiebreaker leaves tied are equal in every column,
      # as far as the original's result shows. It always holds when every
      # column is in the tiebreaker.
      def ties_faithful?(result, positions) = !Tiebreaker.hidden_differences?(result, positions)

      # Whether the original returns the same rows whichever way its ties
      # break, as far as the two tiebreaker runs show.
      def ties_uncut?(ascending, descending)
        ResultComparator.compare(ascending, descending, mode: :multiset).match?
      end

      # CutTies' check, when the original's LIMIT or OFFSET cuts a tie
      # group, or nil.
      def cut_tie(transaction, originals, shapes, positions)
        return unless cut_tie?(transaction, shapes.first, originals, positions)

        rule, fields = CutTies.check(shapes, originals.map(&:rows),
                                     FixtureRuns.new(transaction, positions, originals.first.types))
        ResultComparator::Verdict.for(:ordered, rule, **fields)
      end

      # CutTies' source: tiebreaker runs in the arena transaction, and rows
      # compared as ResultComparator compares them.
      class FixtureRuns
        def initialize(transaction, positions, types)
          @transaction = transaction
          @positions = positions
          @types = types
        end

        def fetch(shape, limited:) = ResultComparison.both_ways(@transaction, shape, @positions, limited:).map(&:rows)
        def key(row) = ResultComparator::Values.key(@types, row)
        def contained?(big, small) = ResultComparator.unpartnered_row(@types, big, small).nil?
        def all_columns? = @positions.size == @types.size
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
    end
  end
end
