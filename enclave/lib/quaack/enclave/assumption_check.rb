# frozen_string_literal: true

require "json"
require "pg_query"
require_relative "assumption_check/denormalized_equal"

module Quaack
  module Enclave
    # DESIGN.md's assumption-check: checks one stated assumption (see RewriteAssumptions for
    # the five kinds) mechanically against pg_constraint and pg_index, or,
    # for denormalized_equal, against the data. NOT VALID constraints count
    # as absent.
    #
    #   AssumptionCheck.met?({ "kind" => "not_null", "table" => "public.orders", "column" => "id" }, connection)
    #   # => true
    #
    # - not_null: a validated NOT NULL or primary key constraint on the column.
    # - unique: a valid unique index on the table, with no predicate and no
    #   expression, not deferrable, whose key columns are all among the
    #   stated ones and are all validated NOT NULL (or NULLS NOT DISTINCT).
    # - foreign_key: a validated foreign key from the table to
    #   references_table, pairing the same columns.
    # - check: a validated CHECK on the table whose expression, deparsed
    #   by pg_query, is identical to the stated one's. Implied constraints
    #   don't count in v1.
    # - denormalized_equal: no row of table, joined to references_table on
    #   join_column = references_column, whose parent's type_column is
    #   type_value, has column IS DISTINCT FROM the parent's id_column. One
    #   EXISTS query on the racetrack, the production clone, in a READ ONLY
    #   transaction under a DenormalizedEqual::TIMEOUT_MS statement timeout. A timeout or
    #   an error is unmet. Only the boolean comes back.
    #
    # A table that doesn't exist meets nothing. connection is read only,
    # with plain SELECTs; the stated values go in as parameters, the stated
    # names as quoted identifiers, and a stated CHECK expression is only
    # parsed, never run.
    module AssumptionCheck
      EQ = "OPERATOR(pg_catalog.=)"

      RELATION = <<~SQL.freeze
        (SELECT c.oid FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid #{EQ} c.relnamespace
         WHERE n.nspname #{EQ} $1 AND c.relname #{EQ} $2)
      SQL

      # A NOT NULL or primary key constraint.
      NOT_NULL_KIND = "(c.contype #{EQ} 'n' OR c.contype #{EQ} 'p')".freeze

      NOT_NULL = <<~SQL.freeze
        SELECT 1 FROM pg_catalog.pg_constraint c
        JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} c.conrelid AND a.attnum #{EQ} ANY (c.conkey)
        WHERE c.conrelid #{EQ} #{RELATION} AND #{NOT_NULL_KIND} AND c.convalidated AND a.attname #{EQ} $3
      SQL

      UNIQUE = <<~SQL.freeze
        SELECT 1 FROM pg_catalog.pg_index i
        WHERE i.indrelid #{EQ} #{RELATION} AND i.indisunique AND i.indisvalid
          AND i.indpred IS NULL AND i.indexprs IS NULL AND i.indimmediate
          AND (i.indnullsnotdistinct OR NOT EXISTS (
            SELECT 1 FROM pg_catalog.unnest(i.indkey::pg_catalog.int2[]) WITH ORDINALITY AS u(k, n)
            WHERE u.n OPERATOR(pg_catalog.<=) i.indnkeyatts AND NOT EXISTS (
              SELECT 1 FROM pg_catalog.pg_constraint c
              WHERE c.conrelid #{EQ} i.indrelid AND #{NOT_NULL_KIND} AND c.convalidated AND u.k #{EQ} ANY (c.conkey))))
          AND NOT EXISTS (
            SELECT 1 FROM pg_catalog.unnest(i.indkey::pg_catalog.int2[]) WITH ORDINALITY AS u(k, n)
            JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} i.indrelid AND a.attnum #{EQ} u.k
            WHERE u.n OPERATOR(pg_catalog.<=) i.indnkeyatts AND a.attname OPERATOR(pg_catalog.<>) ALL ($3::pg_catalog.text[]))
      SQL

      # ROWS FROM, since only an unqualified unnest takes two arrays.
      FOREIGN_KEY = <<~SQL.freeze
        SELECT pg_catalog.array_to_json(ARRAY(
                 SELECT ARRAY[a.attname::pg_catalog.text, r.attname::pg_catalog.text]
                 FROM ROWS FROM (pg_catalog.unnest(c.conkey), pg_catalog.unnest(c.confkey)) AS u(k, f)
                 JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} c.conrelid AND a.attnum #{EQ} u.k
                 JOIN pg_catalog.pg_attribute r ON r.attrelid #{EQ} c.confrelid AND r.attnum #{EQ} u.f))::pg_catalog.text
        FROM pg_catalog.pg_constraint c
        WHERE c.conrelid #{EQ} #{RELATION} AND c.contype #{EQ} 'f' AND c.convalidated
          AND c.confrelid #{EQ} #{RELATION.sub("$1", "$3").sub("$2", "$4")}
      SQL

      CHECK = <<~SQL.freeze
        SELECT pg_catalog.pg_get_constraintdef(c.oid) FROM pg_catalog.pg_constraint c
        WHERE c.conrelid #{EQ} #{RELATION} AND c.contype #{EQ} 'c' AND c.convalidated
      SQL

      module_function

      def met?(assumption, connection)
        table = assumption["table"].split(".", 2)
        case assumption["kind"]
        when "not_null" then any?(connection, NOT_NULL, [*table, assumption["column"]])
        when "unique" then any?(connection, UNIQUE, [*table, text_array(assumption["columns"])])
        when "foreign_key" then foreign_key?(assumption, table, connection)
        when "check" then check?(assumption["expression"], table, connection)
        when "denormalized_equal" then DenormalizedEqual.met?(assumption, connection)
        else false
        end
      end

      def any?(connection, sql, params) = connection.exec_params(sql, params).ntuples.positive?

      def foreign_key?(assumption, table, connection)
        stated = assumption["columns"].zip(assumption["references_columns"]).sort
        return false unless assumption["columns"].size == assumption["references_columns"].size

        referenced = assumption["references_table"].split(".", 2)
        connection.exec_params(FOREIGN_KEY, [*table, *referenced]).column_values(0)
                  .any? { JSON.parse(it).sort == stated }
      end

      def check?(expression, table, connection)
        stated = normalize(expression)
        return false unless stated

        connection.exec_params(CHECK, table).column_values(0)
                  .any? { normalize(it.delete_prefix("CHECK ").delete_suffix(" NO INHERIT")) == stated }
      end

      # The expression's one-statement "SELECT <expression>", deparsed by
      # pg_query with every cast of a constant stripped (Postgres adds
      # them, as in (0)::numeric) and every IN list written as = ANY, or nil if it doesn't parse as exactly that.
      def normalize(expression)
        parse = PgQuery.parse("SELECT #{expression}")
        return unless parse.tree.stmts.size == 1

        strip_constant_casts(parse.tree)
        PgQuery.deparse(parse.tree)
      rescue PgQuery::ParseError
        nil
      end

      def strip_constant_casts(message)
        message.class.descriptor.each do |field|
          value = message[field.name]
          if value.is_a?(Google::Protobuf::RepeatedField)
            value.each_with_index { |item, i| value[i] = stripped(item) if item.is_a?(Google::Protobuf::MessageExts) }
          elsif value.is_a?(Google::Protobuf::MessageExts)
            message[field.name] = stripped(value)
          end
        end
      end

      def stripped(value)
        value = uncast(value) if value.is_a?(PgQuery::Node)
        strip_constant_casts(value)
        value
      end

      def uncast(node)
        node = node.type_cast.arg while node.node == :type_cast && node.type_cast.arg&.node == :a_const
        node.node == :a_expr && node.a_expr.kind == :AEXPR_IN ? any_array(node.a_expr) : node
      end

      # col IN (a, b) as col = ANY (ARRAY[a, b]), and NOT IN as <> ALL,
      # the form Postgres stores a CHECK in. A one-element list it stores
      # as plain = or <>, so that becomes col = a or col <> a.
      def any_array(expr)
        items = expr.rexpr.list.items.to_a
        kind = expr.name.first.string.sval == "=" ? :AEXPR_OP_ANY : :AEXPR_OP_ALL
        kind, rexpr = items.size == 1 ? [:AEXPR_OP, items.first] : [kind, array_of(items)]
        PgQuery::Node.new(a_expr: PgQuery::A_Expr.new(kind:, name: expr.name.to_a, lexpr: expr.lexpr, rexpr:))
      end

      def array_of(items) = PgQuery::Node.new(a_array_expr: PgQuery::A_ArrayExpr.new(elements: items))

      def text_array(values) = "{#{values.map { %("#{it.gsub(/["\\]/) { |c| "\\#{c}" }}") }.join(",")}}"
    end
  end
end
