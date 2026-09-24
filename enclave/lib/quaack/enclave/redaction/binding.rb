# frozen_string_literal: true

require "pg_query"

module Quaack
  module Enclave
    module Redaction
      # A prepared statement's name: a lowercase word.
      STATEMENT_NAME = /\A[a-z_][a-z0-9_]*\z/

      # A query written with the placeholders, such as the redacted query
      # or a rewrite candidate, with the real literals to run it with
      # (README 3g: bind them with PREPARE, never splice them in). See
      # Redaction.binding.
      #
      #   bound = Redaction.binding(sql, placeholder_map)
      #   connection.exec(bound.prepare_sql("quaack_q"))
      #   connection.exec(bound.execute_sql("quaack_q", connection))
      #
      # prepare_sql declares every placeholder's type, $1 through $N of the
      # map, whether the SQL uses it or not, so each $n is typed just as its
      # literal was: an integer as integer, and an untyped string as
      # unknown, which Postgres then types from where it sits. A value goes
      # into EXECUTE as a quoted literal, which Postgres reads with the
      # parameter's type, as SingleCandidateTest does. values, in parameter
      # order, is what SingleCandidateTest takes as one literal set.
      #
      # Trust boundary: values are the literals. inspect leaves them out,
      # and prepare_sql holds only the SQL and the types.
      Binding = Data.define(:sql, :types, :values) do
        def prepare_sql(name)
          declared = types.empty? ? "" : " (#{types.join(", ")})"
          "PREPARE #{checked(name)}#{declared} AS #{sql}"
        end

        # connection is a live PG::Connection, for its escape_literal.
        def execute_sql(name, connection)
          return "EXECUTE #{checked(name)}" if values.empty?

          literals = values.map { |v| v.nil? ? "NULL" : connection.escape_literal(v) }
          "EXECUTE #{checked(name)}(#{literals.join(", ")})"
        end

        def checked(name)
          raise ArgumentError, "a prepared statement's name must be a lowercase word" unless STATEMENT_NAME.match?(name)

          name
        end

        def inspect = "#<data #{self.class} sql=#{sql.inspect}, types=#{types}, values=<redacted>>"

        alias_method :to_s, :inspect

        def pretty_print(pp) = pp.text(inspect)
      end

      # Builds a Binding. The SQL must be exactly one SELECT (Error
      # not_one_select), and each $n in it must be in the map (Error
      # unknown_placeholder).
      module Bind
        module_function

        def for(sql, map)
          parse = parse(sql)
          raise Error, "unknown_placeholder" unless numbers(parse).all? { |n| map.key?("$#{n}") }

          entries = (1..map.size).map { |n| map.fetch("$#{n}") }
          Binding.new(sql:, types: entries.map { it["type"] }.freeze, values: entries.map { it["value"] }.freeze)
        end

        def parse(sql)
          parse = PgQuery.parse(sql)
          stmts = parse.tree.stmts
          raise Error, "not_one_select" unless stmts.size == 1 && stmts.first.stmt.select_stmt

          parse
        rescue PgQuery::ParseError
          raise Error, "not_one_select", cause: nil
        end

        def numbers(parse)
          found = []
          parse.walk! { |_parent, _field, node, _location| found << node.number if node.is_a?(PgQuery::ParamRef) }
          found
        end
      end

      private_constant :Bind
    end
  end
end
