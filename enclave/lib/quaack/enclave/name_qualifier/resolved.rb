# frozen_string_literal: true

require "pg"
require_relative "../deparse"

module Quaack
  module Enclave
    module NameQualifier
      # The functions and operators that several schemas on the path define
      # (task 20261007-21). Postgres picks among them by argument types, so
      # rather than work the types out, this asks Postgres: it plans the
      # query with EXPLAIN (VERBOSE, GENERIC_PLAN) under the plan's search
      # path, as written, and with one call's name put in one candidate
      # schema. A plan shows each function and operator by name, with a
      # schema only where the bare name wouldn't find it, so the plans match
      # only when that schema's overload is the one the bare name resolves
      # to. A call with exactly one matching schema, other than pg_catalog,
      # gets it. A pg_catalog winner stays bare, as NameQualifier leaves
      # pg_catalog's names.
      #
      # It runs inside a savepoint, read-only, so nothing it does lasts, and
      # what it reads never leaves this module: a query that doesn't plan,
      # or a candidate that doesn't resolve, leaves its calls bare, and the
      # error is dropped. The keyword forms and reg literals aren't calls
      # here, so they stay as NameQualifier leaves them.
      module Resolved
        SAVEPOINT = "quaack_resolve_names"
        SET_PATH = "SELECT pg_catalog.set_config('search_path', $1, true)"

        module_function

        # sites is [[name list, schemas with the name], ...]. Changes the
        # lists in place.
        def qualify!(tree, sites, path, connection)
          return if sites.empty?

          baseline = plan(tree, path, connection) or return
          picks = sites.filter_map do |list, schemas|
            pick(list, schemas, baseline) { probe(tree, list, it, path, connection) }
          end
          picks.each { |list, schema| list.unshift(string(schema)) }
          # Every pick together must still plan as written, or none is kept.
          picks.each { it.first.shift } unless plan(tree, path, connection) == baseline
        end

        # [list, the one schema other than pg_catalog whose plan, as the
        # block gives it, matches], or nil.
        def pick(list, schemas, baseline)
          matches = (schemas - ["pg_catalog"]).select { yield(it) == baseline }
          [list, matches.first] if matches.size == 1
        end

        def probe(tree, list, schema, path, connection)
          list.unshift(string(schema))
          plan(tree, path, connection)
        ensure
          list.shift
        end

        def string(schema) = PgQuery::Node.new(string: PgQuery::String.new(sval: schema))

        # The query's plan lines under path, or nil when it doesn't plan.
        def plan(tree, path, connection)
          sql = Deparse.faithfully(tree)
          transaction(connection) { explain(sql, path, connection) }
        rescue Deparse::Error
          nil
        end

        def explain(sql, path, connection)
          connection.exec("SAVEPOINT #{SAVEPOINT}")
          begin
            connection.exec_params(SET_PATH, [path.map { connection.quote_ident(it) }.join(", ")])
            connection.exec("EXPLAIN (VERBOSE, GENERIC_PLAN, COSTS OFF) #{sql}").column_values(0)
          rescue PG::Error
            nil
          ensure
            connection.exec("ROLLBACK TO SAVEPOINT #{SAVEPOINT}")
            connection.exec("RELEASE SAVEPOINT #{SAVEPOINT}")
          end
        end

        # The block inside the connection's transaction, or inside a
        # read-only one of its own that's rolled back.
        def transaction(connection)
          return yield unless connection.transaction_status == PG::PQTRANS_IDLE

          connection.exec("BEGIN READ ONLY")
          begin
            yield
          ensure
            connection.exec("ROLLBACK")
          end
        end
      end
    end
  end
end
