# frozen_string_literal: true

require "pg"
require_relative "../arena_runner"
require_relative "../result_comparator"
require_relative "../result_comparison"

module Quaack
  module Enclave
    module Fuzz
      # Which of Coverage's loosened originals give rows other than the
      # original's on the data the connection's transaction holds now.
      #
      #   Differ.differing(conn, original, [loosened, ...])  # => [0, 2]
      #
      # They go to the server in one statement, each compared with the
      # original as a multiset (EXCEPT ALL both ways), so a world costs one
      # round trip however many directions are pending. A result with a
      # column type that has no equality operator (json, say) fails that
      # statement, and then each is compared alone, by the official
      # comparison. A difference the statement finds is confirmed with the
      # official comparison (ResultComparison) before it counts, so float
      # noise it calls equal doesn't. A tied row's order can't count, since
      # the multisets are equal. A query that fails counts as no difference.
      #
      # Trust boundary: only indexes come back; the rows stay in the arena.
      module Differ
        ORIGINAL = "quaack_coverage_original"

        module_function

        def differing(conn, original, sqls)
          return [] if sqls.empty?

          flagged = saved(conn) { multisets(conn, original, sqls) } || sqls.each_index.to_a
          flagged.select { |index| saved(conn) { official?(conn, original, sqls[index]) } }
        end

        # The indexes whose rows differ from the original's as multisets, or
        # nil when the statement fails.
        def multisets(conn, original, sqls)
          checks = sqls.map do |sql|
            "EXISTS ((#{sql}) EXCEPT ALL (SELECT * FROM #{ORIGINAL})) OR " \
              "EXISTS ((SELECT * FROM #{ORIGINAL}) EXCEPT ALL (#{sql}))"
          end
          row = conn.exec("WITH #{ORIGINAL} AS MATERIALIZED (#{original}) SELECT #{checks.join(", ")}").values.first
          row.each_index.select { row[it] == "t" }
        end

        def official?(conn, original, sql)
          run = ->(query, _index) { result(conn.exec(query)) }
          verdict = ResultComparison.compare(ArenaRunner::Transaction.new(run), original:, candidate: sql)
          !verdict.match? && ResultComparator::MISMATCHES.include?(verdict.rule)
        end

        def result(res)
          types = Array.new(res.nfields) { res.ftype(it) }
          ArenaRunner::Result.new(columns: res.fields, types:, rows: res.values)
        end

        # The block's value, inside a savepoint; nil, rolled back, when it
        # raises a database error or a comparison can't judge.
        def saved(conn)
          conn.exec("SAVEPOINT quaack_atoms")
          value = yield
          conn.exec("RELEASE SAVEPOINT quaack_atoms")
          value
        rescue PG::Error, *UNJUDGED
          conn.exec("ROLLBACK TO SAVEPOINT quaack_atoms")
          nil
        end
      end
    end
  end
end
