# frozen_string_literal: true

require_relative "table_name"
require_relative "index_candidate"
require_relative "predicate_check"
require_relative "statistics"

module Quaack
  module Enclave
    # The 5a-3 filter (README 5a-3): dedupes one index search's candidates
    # and drops the ones not worth testing. One Dedupe is one search: the
    # original query's in 5a, or one rewrite's in steps 8 and 11. Make a new
    # one for each search, so no search sees another's proposals.
    #
    #   search = Dedupe.new(statistics:, low_cardinality: [[orders, "status"]])
    #   survivors = search.filter(GeneratorOne.candidates(parse, statistics))  # to 5a-4
    #   survivors = search.filter(GeneratorTwo.candidates(explain, statistics:))
    #   search.proposals  # every survivor so far, with sources merged
    #   search.set_aside  # GIN, GiST, and SP-GiST survivors, untested, for step 12
    #   search.drops      # a Drop for each candidate dropped, in order
    #   search.considered # how many candidates filter has considered
    #
    # Call filter on each generator's output as soon as it's produced. It
    # returns the candidates from that call worth testing in 5a-4, in order,
    # as a frozen array.
    #
    # statistics is a Statistics. Each table's indexes are the existing
    # indexes. README 3b and 3c fill them in (20260922-19). A table with no
    # statistics raises KeyError, as the generators do.
    #
    # low_cardinality is the columns that README 3f classes as
    # low-cardinality, as [TableName, column name] pairs: fewer than 50
    # distinct values and not PII. PiiClassification#low_cardinality gives
    # them. This class doesn't apply 3f's rule itself.
    #
    # Normalizing. IndexCandidate normalizes each definition when it's built:
    # the nulls ordering each direction defaults to, the method's case, and
    # the predicate as pg_query deparses it. So this compares candidates
    # by their members, through covers?, and never looks at the DDL.
    #
    # Each candidate, in order, meets the first of these that applies:
    #
    # 1. A partial candidate is dropped (:partial_not_low_cardinality)
    #    unless its predicate passes two checks. Every column it uses must
    #    be a bare name (not t.a or t.*, since it can't be sure which column
    #    that is) that's low-cardinality on the candidate's table. And every
    #    constant must be compared directly with one of those columns, as in
    #    status = 'open', status IN ('a', 'b'), status = ANY('{a,b}'), or
    #    status BETWEEN 'a' AND 'm', using a comparison operator (=, <>,
    #    <, <=, >, >=, or LIKE and ILIKE as ~~ and friends), not || or +.
    #    Casts are allowed on the constant and on the column, and COLLATE
    #    on the column, as a plan prints a varchar column,
    #    (status)::text = 'open'::text, if every type modifier is an integer
    #    (see PredicateCheck.constants_compared_with_columns?). Only a
    #    low-cardinality column's values may leave the enclave, so a
    #    constant anywhere else drops the partial, when unsure:
    #    'ssn' = 'ssn', status = lower('bob@x.com'), lower(status) = 'x',
    #    or a bare true. A predicate with no constants, such as flag or
    #    status IS NULL, needs only the column check. Every stored
    #    predicate parses again, since IndexCandidate refuses one that
    #    pg_query can't deparse faithfully (see Deparse). This comes first,
    #    because it's the trust-boundary check (README 5a-3): until a
    #    partial passes it, its predicate may hold PII.
    # 2. A candidate covered by an existing index is dropped
    #    (:covered_by_existing), recording the index as an ExistingIndex.
    #    See covers? for what "covered" means.
    # 3. A candidate equal to an earlier proposal in this search is dropped
    #    (:duplicate), and its sources are added to the earlier proposal.
    #    The drop records the earlier proposal, sources merged, and the
    #    first proposal wins. "Equal" means each covers the other under
    #    covers?, so it follows the coverage rules: INCLUDE order doesn't
    #    count, and a btree with every direction and nulls ordering flipped
    #    is the same index read backward. A prefix of an earlier proposal
    #    isn't dropped, because generator one proposes every leading prefix
    #    on purpose, and 5a-4 tests each.
    # 4. A GIN, GiST, or SP-GiST candidate is set aside, untested, for step
    #    12. HypoPG can't model those methods. The README names GIN and GiST.
    #    The HypoPG in the test image (Postgres 18) refuses SP-GiST as well,
    #    so it goes too.
    #    A set-aside candidate counts as a proposal for step 3.
    # 5. Anything else survives.
    #
    # Trust boundary. A dropped partial candidate's predicate can hold a
    # real literal, and so can a survivor's until 5a-4 runs it. Drop's
    # inspect, to_s, and pp, and this class's, show candidates through
    # IndexCandidate#inspect, which redacts the predicate and every key
    # expression. Pattern matching on a Drop can't reach either, since
    # IndexCandidate's and KeyColumn's deconstruct_keys leave them out. No
    # error here includes a predicate or an expression. Rule 1 doesn't look
    # at key expressions. The README (5a-3) scopes the low-cardinality rule
    # to partial predicates. An expression key comes from an existing
    # index, which the README treats as schema, so shape data, or from the
    # LLM, which only ever saw shape data.
    # to_h and the readers still give the raw candidate, so keep them inside
    # the enclave.
    class Dedupe
      # The methods HypoPG can't model, so their candidates skip 5a-4.
      UNTESTABLE_METHODS = %i[gin gist spgist].freeze

      # An existing index: its name from the catalog and its definition.
      ExistingIndex = Data.define(:name, :definition)

      # One dropped candidate. reason is :partial_not_low_cardinality,
      # :covered_by_existing, or :duplicate. covered_by is the ExistingIndex
      # for :covered_by_existing, the earlier proposal for :duplicate, and
      # nil for :partial_not_low_cardinality. Steps 15a and 15b read these.
      Drop = Data.define(:candidate, :reason, :covered_by)

      def initialize(statistics:, low_cardinality:)
        raise ArgumentError, "statistics must be a Statistics" unless statistics.is_a?(Statistics)

        @statistics = statistics
        @low_cardinality = low_cardinality_set(low_cardinality)
        @drops = []
        @proposals = []
        @set_aside = []
        @considered = 0
      end

      # Every candidate filter has considered. Each one is dropped, set
      # aside, or kept as a proposal, so it should equal their sum. The
      # 15b burndown records it as the count that came in, and checks that.
      # A candidate is counted once it's been considered, so a filter call
      # that raises partway counts only the candidates it got through.
      attr_reader :considered

      def drops = @drops.dup.freeze

      def proposals = @proposals.dup.freeze

      def set_aside = @set_aside.dup.freeze

      def filter(candidates)
        check_candidates(candidates)
        kept = candidates.filter_map do |candidate|
          consider(candidate).tap { @considered += 1 }
        end
        kept.map { |candidate| @proposals.find { |p| p == candidate } }.freeze
      end

      # Whether an existing index covers a candidate: whether 5a-4 would
      # learn nothing new from testing it. All of these must hold:
      #
      # - Same table and same method. A btree doesn't cover a BRIN candidate,
      #   which is worth testing for its size, or the reverse, since a BRIN
      #   can't give order or single-row lookups.
      # - Same predicate, or neither has one. A partial index can't serve a
      #   query its predicate doesn't imply, so it doesn't cover a plain
      #   candidate. A plain index doesn't cover a partial one either,
      #   because the partial is smaller and may win.
      # - For btree, the candidate's key is a leading prefix of the index's,
      #   column for column, with the same direction and nulls ordering, or
      #   with every one flipped (DESC NULLS FIRST for ASC NULLS LAST, and
      #   so on), since a btree can be read backward. A key with some columns
      #   flipped and some not isn't covered. For any other method, the keys
      #   must match exactly: a multicolumn BRIN, hash, or GiST doesn't serve
      #   a query the way a btree's leading prefix does. Key columns match
      #   only when their column or expression, opclass, and collation all
      #   match as KeyColumn normalizes them. So a text_pattern_ops or
      #   COLLATE "C" key isn't covered by a plain one, or the reverse, and
      #   neither is an expression on a column by the column. A default
      #   opclass or collation that's written out doesn't match one that's
      #   left off (see KeyColumn), so that candidate gets tested.
      # - Every INCLUDE column of the candidate is somewhere in the index,
      #   in its key or its INCLUDE list, in any order. An index-only scan
      #   reads a key column as well as an INCLUDE one. A key column of the
      #   candidate that the index only INCLUDEs isn't covered.
      # - A unique candidate needs a unique index with the same number of
      #   key columns. A unique index covers a plain candidate like any other.
      #
      # An existing index that IndexCandidate couldn't represent (nil in
      # TableStatistics#indexes), such as one with an opclass that takes
      # parameters or NULLS NOT DISTINCT, never covers anything. The shape can't say
      # what it serves, so the candidate gets tested.
      def self.covers?(index, candidate) = Coverage.covers?(index, candidate)

      def inspect
        "#<#{self.class} proposals=#{@proposals.inspect}, set_aside=#{@set_aside.inspect}, drops=#{@drops.inspect}>"
      end

      alias to_s inspect

      def pretty_print(pp) = pp.text(inspect)

      private

      # Returns the candidate if it survives, or nil, recording why not.
      def consider(candidate)
        indexes = @statistics.table(candidate.table).indexes
        if partial_not_low_cardinality?(candidate)
          drop(candidate, :partial_not_low_cardinality, nil)
        elsif (index = covering_index(candidate, indexes))
          drop(candidate, :covered_by_existing, index)
        elsif (earlier = merge_into_earlier(candidate))
          drop(candidate, :duplicate, earlier)
        else
          keep(candidate)
        end
      end

      # A survivor is a proposal. It's returned for 5a-4, unless HypoPG
      # can't model it, so it's set aside.
      def keep(candidate)
        if UNTESTABLE_METHODS.include?(candidate.access_method)
          @set_aside << candidate
          return nil
        end

        @proposals << candidate
        candidate
      end

      def drop(candidate, reason, covered_by)
        @drops << Drop.new(candidate:, reason:, covered_by:)
        nil
      end

      def partial_not_low_cardinality?(candidate)
        return false if candidate.predicate.nil?

        PredicateCheck.predicate_columns(candidate.predicate).any? do |column|
          !@low_cardinality.include?([candidate.table, column])
        end || !PredicateCheck.constants_compared_with_columns?(candidate.predicate)
      end

      def covering_index(candidate, indexes)
        indexes.each do |name, index|
          return ExistingIndex.new(name:, definition: index) if index && self.class.covers?(index, candidate)
        end
        nil
      end

      # Merges the candidate's sources into the earlier proposal that's the
      # same index as it, if there is one, and returns the merged proposal.
      # Two candidates are the same index when each covers the other.
      def merge_into_earlier(candidate)
        [@proposals, @set_aside].each do |list|
          i = list.index { |p| Coverage.covers?(p, candidate) && Coverage.covers?(candidate, p) }
          return list[i] = list[i].with(sources: list[i].sources | candidate.sources) if i
        end
        nil
      end

      def check_candidates(candidates)
        return if candidates.is_a?(Array) && candidates.all?(IndexCandidate)

        raise ArgumentError, "filter takes an Array of IndexCandidates"
      end

      def low_cardinality_set(pairs)
        valid = pairs.respond_to?(:all?) && pairs.all? { |pair| column_pair?(pair) }
        raise ArgumentError, "low_cardinality must be [TableName, column name] pairs" unless valid

        pairs.to_set { |table, column| [table, column.dup.freeze].freeze }.freeze
      end

      def column_pair?(pair)
        pair.is_a?(Array) && pair.size == 2 && pair[0].is_a?(TableName) && pair[1].is_a?(String) && !pair[1].empty?
      end

      # The rules behind Dedupe.covers?.
      module Coverage
        module_function

        def covers?(index, candidate)
          same_kind?(index, candidate) && key_covered?(index, candidate) &&
            unique_covered?(index, candidate) && include_covered?(index, candidate)
        end

        def same_kind?(index, candidate)
          [index.table, index.access_method, index.predicate] ==
            [candidate.table, candidate.access_method, candidate.predicate]
        end

        def unique_covered?(index, candidate)
          !candidate.unique || (index.unique && index.key.size == candidate.key.size)
        end

        def include_covered?(index, candidate) = (candidate.include - index.key.map(&:name) - index.include).empty?

        def key_covered?(index, candidate)
          return index.key == candidate.key unless candidate.access_method == :btree

          prefix = index.key.first(candidate.key.size)
          [prefix, prefix.map { |k| reversed(k) }].include?(candidate.key)
        end

        def reversed(key_column)
          key_column.with(direction: key_column.direction == :asc ? :desc : :asc,
                          nulls: key_column.nulls == :first ? :last : :first)
        end
      end

      private_constant :Coverage
    end
  end
end
