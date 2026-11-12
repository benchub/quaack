# frozen_string_literal: true

require_relative "../function_calls"

module Quaack
  module Enclave
    module ResultComparison
      # A nondeterministic collation makes the ordered comparison refuse,
      # since values it calls equal, such as 'a' and 'A', can tie in the
      # sort and print differently. That can't happen when the original's
      # ORDER BY is a total order fixed by the data: its top SELECT is
      # deterministic as an inner cut would be (InnerCuts: one table read
      # once, which a WHERE's IN or EXISTS semijoin never repeats, no GROUP
      # BY, DISTINCT, or set operation, sorted by every column of a
      # not-null unique key), and that key's columns have deterministic
      # collations. Then the original's rows have one order, and the two
      # results compare row for row. A candidate that ties can only lose.
      module TotalOrder
        # Keeps only keys whose columns have no collation or a deterministic one.
        DETERMINISTIC_KEYS_SQL = <<~SQL
          AND NOT EXISTS (
            SELECT FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_collation co ON co.oid OPERATOR(pg_catalog.=) a.attcollation
            WHERE a.attrelid OPERATOR(pg_catalog.=) i.indrelid
              AND a.attnum OPERATOR(pg_catalog.=) ANY (i.indkey::pg_catalog.int2[]) AND NOT co.collisdeterministic)
        SQL

        # Output types that carry no collation, so a nondeterministic one
        # can't make two rows print differently while the tiebreaker calls
        # them equal: bool, int2, int4, int8, oid, float4, float8, numeric,
        # date, time, timetz, timestamp, timestamptz, interval, uuid.
        COLLATION_FREE_OIDS = [
          16, 20, 21, 23, 26, 700, 701, 1082, 1083, 1114, 1184, 1186, 1266, 1700, 2950
        ].to_set.freeze

        module_function

        # :none when neither shape meets a nondeterministic collation, or
        # when no output column (types are their OIDs) can hold text and no
        # COLLATE clause names one, :total when one does but the original's
        # order is total, and nil, to refuse, otherwise.
        def gate(transaction, shapes, types)
          return :none if shapes.all? { it.collation_names.empty? } && types.all?(COLLATION_FREE_OIDS)
          return :none unless Tiebreaker.nondeterministic_collation?(transaction, shapes.flat_map(&:collation_names))

          :total if !returns_set?(transaction, shapes.first.sql) && keyed?(transaction, shapes.first.tree)
        end

        def keyed?(transaction, tree)
          top = tree[:stmts].first[:stmt][:select_stmt]
          InnerCuts.deterministic?(transaction, top, InnerCuts.cte_names(tree), DETERMINISTIC_KEYS_SQL)
        end

        # A function of the name, unqualified or as schema.name, or an
        # operator of the name, that returns a set.
        SET_RETURNING_SQL = <<~SQL
          SELECT pg_catalog.count(*)::int FROM pg_catalog.pg_proc p
          JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) p.pronamespace
          WHERE p.proretset
            AND (p.proname OPERATOR(pg_catalog.=) ANY ('{%<names>s}'::pg_catalog.name[])
              OR pg_catalog.concat(n.nspname, '.', p.proname) OPERATOR(pg_catalog.=) ANY ('{%<qualified>s}'::pg_catalog.text[])
              OR p.oid OPERATOR(pg_catalog.=) ANY (
                SELECT o.oprcode::pg_catalog.oid FROM pg_catalog.pg_operator o
                WHERE o.oprname OPERATOR(pg_catalog.=) ANY ('{%<operators>s}'::pg_catalog.name[])))
        SQL

        # Whether the target list calls a function or operator that could
        # return a set, by the catalog, so one key's row can repeat, once
        # for each of its values, and tie in the sort. Which overload
        # Postgres would pick isn't worked out, so one of the name is enough.
        def returns_set?(transaction, sql)
          calls = target_calls(sql)
          return false if calls.empty?

          transaction.query(returns_set_sql(calls)).rows.first.first != "0"
        end

        def returns_set_sql(calls)
          functions, operators = calls.partition { it.kind == :function }
          qualified, names = functions.partition(&:schema)
          format(SET_RETURNING_SQL, names: elements(names.map(&:name)),
                                    qualified: elements(qualified.map { "#{it.schema}.#{it.name}" }),
                                    operators: elements(operators.map(&:name)))
        end

        def target_calls(sql)
          targets = PgQuery.parse(sql).tree.stmts.first.stmt.select_stmt.target_list
          found = []
          own_level_calls(targets, found)
          found.select { %i[function operator].include?(it.kind) }.uniq
        end

        # FunctionCalls' walk, but it stops at a subquery: a SubLink gives
        # one value a row however many its own SELECT reads, so only the
        # left side of an IN or ANY counts.
        def own_level_calls(node, found)
          case node
          when Google::Protobuf::RepeatedField then node.each { own_level_calls(it, found) }
          when PgQuery::SubLink then own_level_calls(node.testexpr, found)
          when Google::Protobuf::MessageExts
            handler = FunctionCalls::HANDLERS[node.class]
            found.concat(FunctionCalls.send(handler, node)) if handler
            node.class.descriptor.each { own_level_calls(it.get(node), found) }
          end
        end

        # The texts as an array literal's elements, inside a string literal.
        def elements(texts)
          texts.map { %("#{it.gsub(/["\\]/) { "\\#{it}" }}") }.join(",").gsub("'", "''")
        end

        # The original's order is total, so the results compare row for row.
        def compare(transaction, *shapes)
          ResultComparator.compare(*shapes.map { transaction.query(it.sql) }, mode: :ordered)
        end
      end
    end
  end
end
