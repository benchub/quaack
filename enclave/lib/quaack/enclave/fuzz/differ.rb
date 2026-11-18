# frozen_string_literal: true

require "pg"
require_relative "../arena_runner"
require_relative "../result_comparator"
require_relative "../result_comparison"
require_relative "../server_clock"

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
        QUERY_CANCELED = "57014"

        module_function

        # typed (an ArenaRunner::Typed) gives each statement's parameters,
        # for the $n the queries hold (task 20261110-14).
        def differing(conn, original, sqls, typed = ArenaRunner::Typed.new(nil), statement_timeout_ms: nil)
          return [] if sqls.empty?

          timeout = statement_timeout_ms
          flagged = saved(conn, timeout) { multisets(conn, original, sqls, typed) } || sqls.each_index.to_a
          flagged.select { |index| saved(conn, timeout) { official?(conn, original, sqls[index], typed) } }
        end

        # The indexes whose rows differ from the original's as multisets, or
        # nil when the statement fails.
        def multisets(conn, original, sqls, typed)
          checks = sqls.map do |sql|
            "EXISTS ((#{sql}) EXCEPT ALL (SELECT * FROM #{ORIGINAL})) OR " \
              "EXISTS ((SELECT * FROM #{ORIGINAL}) EXCEPT ALL (#{sql}))"
          end
          sql = "WITH #{ORIGINAL} AS MATERIALIZED (#{original}) SELECT #{checks.join(", ")}"
          row = conn.exec_params(sql, typed.params(conn, sql)).values.first
          row.each_index.select { row[it] == "t" }
        end

        def official?(conn, original, sql, typed)
          run = ->(query, _index) { result(conn.exec_params(query, typed.params(conn, query))) }
          verdict = ResultComparison.compare(ArenaRunner::Transaction.new(run, typed.binding), original:,
                                                                                               candidate: sql)
          !verdict.match? && ResultComparator::MISMATCHES.include?(verdict.rule)
        end

        def result(res)
          types = Array.new(res.nfields) { res.ftype(it) }
          ArenaRunner::Result.new(columns: res.fields, types:, rows: res.values)
        end

        # The block's value, inside a savepoint; nil, rolled back, when it
        # raises a database error or a comparison can't judge. A cancel
        # counts so only when it's QUAACK's statement_timeout_ms, by the
        # server's clock (ServerClock); any other cancel, such as an
        # operator's pg_cancel_backend, says nothing about the atom, so it
        # raises statement_canceled, ending the step (task 20261012-52).
        def saved(conn, timeout_ms)
          started = ServerClock.mark(conn, "SAVEPOINT quaack_atoms;")
          value = yield
          conn.exec("RELEASE SAVEPOINT quaack_atoms")
          value
        rescue PG::QueryCanceled
          canceled(conn, started, timeout_ms)
        rescue PG::Error, *UNJUDGED
          conn.exec("ROLLBACK TO SAVEPOINT quaack_atoms")
          nil
        end

        # nil after QUAACK's own timeout; any other cancel raises.
        def canceled(conn, started, timeout_ms)
          timed_out = timeout_ms && ServerClock.timed_out?(conn, started, timeout_ms)
          conn.exec("ROLLBACK TO SAVEPOINT quaack_atoms")
          return nil if timed_out

          raise ArenaRunner::Error.new(:statement_canceled, step: :query, sqlstate: QUERY_CANCELED), cause: nil
        end
      end
    end
  end
end
