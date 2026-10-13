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

module Quaack
  module Enclave
    # rewrite-test's fuzz search (task 20261012-2, DESIGN.md's rewrite-test):
    # random small databases on the two queries' own tables, built around
    # their own values, to disprove a rewrite before ScenarioTests runs.
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
    # couldn't be set up, such as honoured copies that can't be kept, or no
    # world in which both queries ran). trials counts the worlds compared.
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
      Outcome = Data.define(:verdict, :rule, :trials, :sizes)

      class Error < StandardError
        def initialize(message = "a fuzz query names a table without its schema") = super
      end

      LIFTS = 5
      SHRINKS = 200
      UNJUDGED = [ResultComparison::Error, SupportedSql::Error].freeze

      module_function

      def run(conn, original, candidate, stop:, honour: [], seed: nil, # rubocop:disable Metrics/ParameterLists
              statement_timeout_ms: ArenaRunner::DEFAULT_STATEMENT_TIMEOUT_MS)
        queries = [original, candidate]
        queries.each_with_index { |sql, i| ArenaRunner::StatementCheck.check(sql, :query, i) }
        footprint = footprint(queries)
        return untested if footprint.empty? || unjudged?(original, candidate)

        quietly(conn) do
          Search.new(conn, footprint, queries, honour:, statement_timeout_ms:)
                .call(stop, Random.new(seed || seed(*queries)))
        end
      end

      # Drops the server's notices while the block runs.
      def quietly(conn)
        previous = conn.set_notice_receiver { nil }
        yield
      ensure
        conn.set_notice_receiver(&previous) unless conn.finished?
      end

      def untested = Outcome.new(verdict: :untested, rule: nil, trials: 0, sizes: [])

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
      class Search
        def initialize(conn, footprint, queries, honour:, statement_timeout_ms:)
          @queries = %i[original candidate].zip(queries).to_h
          @catalog = Catalog.new(conn, footprint)
          @domains = Domains.new(conn, @catalog, queries)
          @generator = Generator.new(@catalog, @domains)
          @session = Session.new(conn, @catalog, queries, honour:, statement_timeout_ms:)
          @lift = Lift.new(conn, @catalog, @domains, honour:, statement_timeout_ms:)
          @compared = 0
          @lifts = 0
        end

        def call(stop, rng)
          return Fuzz.untested unless open

          search(stop, rng)
        rescue Deadline::Expired
          ended
        ensure
          @session.close
        end

        private

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
          trial = @session.trial(rows)
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

        def ended = @compared.zero? ? Fuzz.untested : outcome(:passed)

        def outcome(verdict, rule = nil, sizes = [])
          Outcome.new(verdict:, rule:, trials: @compared, sizes:)
        end

        # The kill shrunk and lifted, as a disproof, or nil, with the
        # session open again to search on.
        def lifted(rows)
          @lifts += 1
          rows = shrink(rows)
          @session.close
          rule = @lift.call(rows, **@queries)
          return outcome(:disproved, rule, sizes(rows)) if rule

          @session.open
          nil
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
