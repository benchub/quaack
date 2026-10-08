# frozen_string_literal: true

require "json"
require_relative "../stats_payload"

module Quaack
  module Enclave
    module PlannerStatistics
      # pg_stats shows a column's row only to a role that can SELECT the
      # column (and, with row security active, none at all), so a role
      # with limited privileges would get no statistics for it, with no
      # error. This catches that for the query's columns. Of those,
      # the ones pg_statistic has a row for must all be in pg_stats. When
      # the role can't read pg_statistic, which most can't, each must be
      # one it can SELECT. The refusal, column_statistics_hidden, names the
      # table, never the column. Every comparison names pg_catalog's
      # operator, as Catalog's do.
      module Visibility
        # Whether the role can read pg_statistic, the catalog pg_stats is a
        # view of. Most roles can't: only a superuser can, unless granted.
        STATISTIC_READABLE_SQL = "SELECT pg_catalog.has_table_privilege('pg_catalog.pg_statistic', 'SELECT')"

        # Of the columns $2 names, a JSON array, those pg_statistic has a
        # row for.
        ANALYZED_SQL = <<~SQL
          SELECT a.attname FROM pg_catalog.pg_statistic s
          JOIN pg_catalog.pg_attribute a ON a.attrelid OPERATOR(pg_catalog.=) s.starelid
           AND a.attnum OPERATOR(pg_catalog.=) s.staattnum
          WHERE s.starelid OPERATOR(pg_catalog.=) $1 AND NOT s.stainherit AND NOT a.attisdropped
           AND a.attname::pg_catalog.text OPERATOR(pg_catalog.=)
               ANY (ARRAY(SELECT pg_catalog.json_array_elements_text($2::pg_catalog.json)))
        SQL

        # Of the columns $2 names, those the role can't SELECT, which
        # pg_stats leaves out.
        UNSELECTABLE_SQL = <<~SQL
          SELECT a.attname FROM pg_catalog.pg_attribute a
          WHERE a.attrelid OPERATOR(pg_catalog.=) $1 AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
           AND a.attname::pg_catalog.text OPERATOR(pg_catalog.=)
               ANY (ARRAY(SELECT pg_catalog.json_array_elements_text($2::pg_catalog.json)))
           AND NOT pg_catalog.has_column_privilege($1, a.attnum, 'SELECT')
        SQL

        module_function

        # entry is the table's stored entry, its names in UTF-8. query is
        # the qualified query, or nil to check every column.
        def check!(table, oid, entry, query, connection)
          names = query_columns(entry, query)
          return if names.empty?

          readable = connection.exec_params(STATISTIC_READABLE_SQL, []).getvalue(0, 0) == "t"
          sql = readable ? ANALYZED_SQL : UNSELECTABLE_SQL
          found = connection.exec_params(sql, [oid, JSON.generate(names)]).column_values(0)
                            .map { it.encode(Encoding::UTF_8) }
          hidden = readable ? found - entry["columns"].keys : found
          raise Error.new("column_statistics_hidden", "pg_stats hides column statistics of #{table}") if hidden.any?
        end

        # The table's columns the query references (see StatsPayload), or
        # every column when there's no query.
        def query_columns(entry, query)
          return entry["column_names"] if query.nil?

          outbound = { "tables" => [{ "schema" => entry["schema"], "name" => entry["name"],
                                      "columns" => entry["column_names"].map { { "name" => it } } }] }
          StatsPayload.subset(outbound, [query])["tables"].first["columns"].map { it["name"] }
        end
      end
    end
  end
end
