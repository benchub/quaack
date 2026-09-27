# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    # The Postgres grammar pg_query parses with. pg_query 6.2.3 ships the
    # Postgres 17 parser, while production runs Postgres 18, so a parse
    # refusal adds NOTE to say a Postgres 18-only construct may be the cause.
    # NOTE is fixed text: it never carries the SQL or pg_query's own error,
    # which can quote the SQL. Drop it once pg_query parses Postgres 18.
    module ParserVersion
      MAJOR = PgQuery::PG_VERSION_NUM / 10_000
      NOTE = "pg_query parses with the Postgres #{MAJOR} grammar; " \
             "Postgres #{MAJOR + 1}-only syntax isn't supported yet".freeze

      # message, followed by NOTE in parentheses.
      def self.unparsable(message) = "#{message} (#{NOTE})"
    end
  end
end
