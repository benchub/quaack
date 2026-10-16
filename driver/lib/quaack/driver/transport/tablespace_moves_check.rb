# frozen_string_literal: true

require "quaack/protocol/tablespace_moves"

module Quaack
  module Driver
    module Transport
      # A report's tablespace_moves, as egress checks it: when the report
      # has one, it must name only tables the report's own original_sql
      # names, schema-qualified (see Protocol::TablespaceMoves.within?), so
      # no other relation's name comes through under it.
      module TablespaceMovesCheck
        module_function

        def ok?(line)
          !line.key?("tablespace_moves") ||
            Protocol::TablespaceMoves.within?(line["tablespace_moves"], tables(line["original_sql"]))
        end

        # The [schema, name] of each schema-qualified table sql names, or
        # none when it isn't SQL that parses. pg_query loads only here, so
        # Reply loads without it, as it must outside Bundler.
        def tables(sql)
          return [] unless sql.is_a?(String)

          require "pg_query"

          PgQuery.parse(sql).tables_with_details.filter_map do |table|
            [table[:schemaname], table[:relname]] unless table[:schemaname].to_s.empty?
          end
        rescue PgQuery::ParseError
          []
        end
      end
    end
  end
end
