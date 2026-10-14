# frozen_string_literal: true

require "pg"
require "pg_query"
require "quaack/protocol/fuzz_result"
require_relative "arena_runner"
require_relative "deadline"
require_relative "result_comparison"
require_relative "scenarios"
require_relative "supported_sql"
require_relative "fuzz/stop_rule"
require_relative "fuzz/signature"
require_relative "fuzz/catalog"
require_relative "fuzz/domains"
require_relative "fuzz/generator"
require_relative "fuzz/session"
require_relative "fuzz/lift"
require_relative "fuzz/enumerate"
require_relative "fuzz/coverage"
require_relative "predicate_atoms"

module Quaack
  module Enclave
    # rewrite-test's fuzz search (task 20261012-2, DESIGN.md's rewrite-test):
    # random small databases on the two queries' own tables, built around
    # their own values, to disprove a rewrite.
    #
    #   Fuzz.run(arena, original, candidate, stop: Fuzz::StopRule.from_env(ENV), honour: copies)
    #   # => Outcome(verdict: :disproved, rule: :row_count, trials: 12, sizes: [["s", "orders", 2]])
    #
    # Each trial is a world from Generator, loaded and compared by Session
    # in one rolled-back transaction with the foreign keys out of the
    # footprint dropped. Its Signature feeds the StopRule, which ends the
    # search, and so does the rewrite's Deadline (Deadline.check! before
    # each trial). A kill is shrunk, one row at a time, to a world where no
    # row can go, then the session rolls back and Lift checks it with every
    # constraint enforced. Only a lifted kill disproves; one that doesn't
    # lift is dropped and the search goes on, up to LIFTS of them.
    #
    # verdict is :disproved, :passed (the search ran out its stop rule or
    # the deadline with at least one world compared), or :untested (no
    # footprint, a query the comparison can't judge, a session that
    # couldn't be set up, such as honoured copies that can't be kept, no
    # world in which both queries ran, or a deadline that ran out while a
    # kill was shrunk or lifted, which leaves enumerate untested too).
    # trials counts the worlds compared.
    # sizes are a disproof's rows per table, as [schema, table, count] for
    # each footprint table with rows, sorted; the rows themselves never
    # leave here.
    #
    # The seed is from the two queries' text, so the same pair searches the
    # same worlds, and a run can be repeated by hand.
    #
    # It raises ArenaRunner::Error statement_not_allowed for a query that
    # isn't a plain SELECT, before it touches the arena, and Error for a
    # query that names a table without its schema, whose footprint can't
    # be read: a search on it would test nothing.
    module Fuzz
      Outcome = Data.define(:verdict, :rule, :trials, :sizes, :reason)

      class Error < StandardError
        def initialize(message = "a fuzz query names a table without its schema") = super
      end

      # The rewrite's Deadline ran out while a kill was shrunk or lifted
      # (Search#confirm), so both searches are untested.
      class Unconfirmed < StandardError
        def initialize(message = "the rewrite's time budget ran out while a kill was confirmed") = super
      end

      # Why an outcome is untested (task 20261012-4): the queries read no
      # table, the comparison can't judge them (FETCH FIRST ... WITH TIES,
      # say), the session couldn't be set up, no world let both queries
      # run, the deadline ran out before a world was compared, or while a
      # kill was confirmed (Unconfirmed). Steps::RewriteFuzz adds its own.
      REASONS = %i[no_tables not_comparable setup_failed no_world out_of_time unconfirmed].freeze

      LIFTS = 5
      SHRINKS = 200
      UNJUDGED = [ResultComparison::Error, SupportedSql::Error].freeze

      module_function

      # The fuzz search's Outcome and enumerate's (Enumerate::Outcome), and
      # which of the original's atoms their worlds showed both ways
      # (Coverage::Result), or nil when no search ran.
      Results = Data.define(:fuzz, :enumerate, :coverage)

      def run(conn, original, candidate, stop:, **) = search(conn, original, candidate, stop:, enumerate: nil, **).fuzz

      # The fuzz search, then, if it passed and enumerate is an
      # Enumerate::Limit, enumerate in the same session, as Results. An
      # error in enumerate makes it untested and leaves fuzz's outcome as it
      # was; a cancel QUAACK didn't send is raised, from either.
      def search(conn, original, candidate, stop:, enumerate:, honour: [], seed: nil, # rubocop:disable Metrics/ParameterLists
                 statement_timeout_ms: ArenaRunner::DEFAULT_STATEMENT_TIMEOUT_MS)
        queries = [original, candidate]
        queries.each_with_index { |sql, i| ArenaRunner::StatementCheck.check(sql, :query, i) }
        footprint = footprint(queries)
        return unsearched(:no_tables) if footprint.empty?
        return unsearched(:not_comparable) if unjudged?(*queries)

        quietly(conn) do
          Search.new(conn, footprint, queries, honour:, statement_timeout_ms:)
                .call(stop, Random.new(seed || seed(*queries)), enumerate)
        end
      end

      # Drops the server's notices while the block runs.
      def quietly(conn)
        previous = conn.set_notice_receiver { nil }
        yield
      ensure
        conn.set_notice_receiver(&previous) unless conn.finished?
      end

      # An untested Outcome, with why (REASONS).
      def untested(reason) = Outcome.new(verdict: :untested, rule: nil, trials: 0, sizes: [], reason:)

      def unsearched(reason) = Results.new(fuzz: untested(reason), enumerate: Enumerate.untested, coverage: nil)

      # The tables both queries name, raising Error for one named without
      # its schema that isn't a CTE's.
      def footprint(sqls)
        sqls.flat_map do |sql|
          tree = PgQuery.parse(sql).tree
          raise Error if unqualified?(tree.to_h)

          Scenarios.query_tables(tree)
        end.uniq
      end

      def unqualified?(tree)
        ctes = []
        relations = []
        walk(tree) do |node|
          ctes << node[:ctename] if node.key?(:ctename)
          relations << node[:range_var] if node.key?(:range_var)
        end
        relations.any? { it[:schemaname].to_s.empty? && !ctes.include?(it[:relname]) }
      end

      def walk(node, &)
        case node
        when Hash
          yield node
          node.each_value { walk(it, &) }
        when Array then node.each { walk(it, &) }
        end
      end

      def unjudged?(original, candidate)
        ResultComparison::Shape.parse(candidate, :candidate)
        ResultComparison::Shape.parse(original, :original).mode == :with_ties
      rescue *UNJUDGED
        true
      end

      # FNV-1a over both queries, so no digest library is needed.
      def seed(*sqls)
        sqls.join("\0").each_byte.reduce(0xcbf29ce484222325) { |h, b| ((h ^ b) * 0x100000001b3) % (2**64) }
      end

      # One search's state.
      class Search # rubocop:disable Metrics/ClassLength -- one search's state, the atoms' coverage included
        def initialize(conn, footprint, queries, honour:, statement_timeout_ms:)
          @queries = %i[original candidate].zip(queries).to_h
          @catalog = Catalog.new(conn, footprint)
          @domains = Domains.new(conn, @catalog, queries)
          @generator = Generator.new(@catalog, @domains)
          @session = Session.new(conn, @catalog, queries, honour:, statement_timeout_ms:)
          @lift = Lift.new(conn, @catalog, @domains, honour:, statement_timeout_ms:)
          @coverage = Coverage.new(PredicateAtoms.extract(PgQuery.parse(queries.first),
                                                          column_names: @catalog.schema.column_names), queries.first)
          @compared = 0
          @lifts = 0
        end

        def call(stop, rng, limit)
          return results(Fuzz.untested(:setup_failed)) unless open

          fuzz = fuzzed(stop, rng)
          results(fuzz, fuzz.verdict == :passed && limit ? enumerate(limit) : Enumerate.untested)
        rescue Unconfirmed
          results(Fuzz.untested(:unconfirmed))
        ensure
          close
        end

        # One trial on rows in the session, its world observed for the
        # atoms' coverage.
        def trial(rows) = observed(@session.trial(rows))

        # A kill shrunk and lifted, as [rule, sizes], or nil, with the
        # session open again to go on. Raises Unconfirmed if the deadline
        # runs out meanwhile.
        def confirm(rows)
          rows = shrink(rows)
          @session.close
          rule = @lift.call(rows, **@queries)
          return [rule, sizes(rows)] if rule

          @session.open
          nil
        rescue Deadline::Expired
          raise Unconfirmed
        end

        private

        def results(fuzz, enumerate = Enumerate.untested) = Results.new(fuzz:, enumerate:, coverage: @coverage.result)

        # trial, once Coverage has seen its world if it compared and didn't kill.
        def observed(trial)
          @coverage.observe(@session) if trial.compared && !trial.kill?
          trial
        end

        # Rolls the session back. A backend that died, in enumerate say, has
        # nothing left to roll back, and its error mustn't replace the result.
        def close
          @session.close
        rescue PG::Error
          nil
        end

        def fuzzed(stop, rng)
          search(stop, rng)
        rescue Deadline::Expired
          ended(:out_of_time)
        end

        # Enumerate's outcome, or untested if it fails, so fuzz's pass
        # stands. A cancel QUAACK didn't send still ends the step.
        def enumerate(limit)
          kinds = Enumerate::Kinds.new(@catalog, @generator.plan, @domains)
          Enumerate::Run.new(self, Enumerate::Worlds.new(@catalog, @generator.plan, @domains, kinds), limit).call
        rescue Error, ArenaRunner::Error, PG::Error, Deadline::Expired => e
          raise if e.is_a?(ArenaRunner::Error) && ArenaRunner::Cancel.foreign?(e)

          Enumerate.untested
        end

        def search(stop, rng)
          until stop.stop? || @lifts >= LIFTS
            Deadline.check!
            rows = @generator.world(rng)
            next unless killed?(stop, rows)

            outcome = lifted(rows)
            return outcome if outcome
          end
          ended
        end

        # Runs a trial on rows, and gives whether it killed.
        def killed?(stop, rows)
          trial = trial(rows)
          stop.observe(trial.signature)
          @compared += 1 if trial.compared
          trial.kill?
        end

        def open
          @session.open
          true
        rescue ArenaRunner::Error, PG::Error
          false
        end

        # A pass, or untested, by why, when no world was compared.
        def ended(why = :no_world) = @compared.zero? ? Fuzz.untested(why) : outcome(:passed)

        def outcome(verdict, rule = nil, sizes = [])
          Outcome.new(verdict:, rule:, trials: @compared, sizes:, reason: nil)
        end

        # The kill shrunk and lifted, as a disproof, or nil, with the
        # session open again to search on.
        def lifted(rows)
          @lifts += 1
          rule, sizes = confirm(rows)
          outcome(:disproved, rule, sizes) if rule
        end

        # Drops one row at a time while the world still kills, until no row
        # can go or SHRINKS trials are spent. A row whose removal orphans
        # another fails to load, so it stays.
        def shrink(rows)
          @shrinks = 0
          while (smaller = smaller(rows))
            rows = smaller
          end
          rows
        end

        # rows less one row, the last it can drop, that still kills, or nil.
        def smaller(rows)
          (rows.size - 1).downto(0) do |i|
            Deadline.check!
            return nil if (@shrinks += 1) > SHRINKS

            fewer = rows[0...i] + rows[(i + 1)..]
            return fewer if @session.trial(fewer).kill?
          end
          nil
        end

        # Each table's rows, but at most Protocol::FuzzResult::MAX_SIZE,
        # which means that many or more: a copies world can hold a query
        # constant's worth of rows, and the count mustn't carry it out.
        def sizes(rows)
          rows.group_by(&:table).map do |table, group|
            [table.schema, table.name, [group.size, Protocol::FuzzResult::MAX_SIZE].min]
          end.sort
        end
      end
    end
  end
end
