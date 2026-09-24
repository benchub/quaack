# frozen_string_literal: true

require "pg_query"
require_relative "error"
require_relative "../supported_sql"

module Quaack
  module Enclave
    module Intake
      # Checks the query text from the operator's file, in this order, and
      # returns it as given, comments and layout included:
      #
      # 1. query_not_text: it isn't UTF-8, or it holds a NUL byte. pg_query
      #    reads the text as a C string, so it would stop at a NUL and check
      #    only what came before it.
      # 2. query_unparsable: pg_query can't parse it. Its error quotes the
      #    text, so it's left behind.
      # 3. query_not_one_statement: it's empty, or holds more than one
      #    statement.
      # 4. unsupported_construct: SupportedSql refuses it. That also refuses
      #    anything but SELECT, SELECT INTO, and locking clauses.
      # 5. query_has_parameters: it has a $n parameter, as a query copied
      #    from pg_stat_statements does. It can't be replayed without the
      #    values, and 3g uses $n for its own placeholders.
      #
      # One leading byte order mark, which some editors write, is dropped
      # first, since pg_query can't parse it.
      module Query
        BOM = "﻿"

        module_function

        def check(bytes)
          text = bytes.dup.force_encoding(Encoding::UTF_8)
          raise Error, "query_not_text" unless text.valid_encoding? && !text.include?("\0")

          text = text.delete_prefix(BOM)
          parse = parse(text)
          raise Error, "query_not_one_statement" unless parse.tree.stmts.size == 1

          supported!(parse)
          raise Error, "query_has_parameters" if parameters?(parse)

          text
        end

        def parameters?(parse)
          found = false
          parse.walk! { |_parent, _field, node, _location| found ||= node.is_a?(PgQuery::ParamRef) }
          found
        end

        def parse(text)
          PgQuery.parse(text)
        rescue PgQuery::ParseError
          raise Error, "query_unparsable", cause: nil
        end

        def supported!(parse)
          SupportedSql.check!(parse)
        rescue SupportedSql::Error
          raise Error, "unsupported_construct", cause: nil
        end
      end
    end
  end
end
