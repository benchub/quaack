# frozen_string_literal: true

require_relative "../assumption_check"
require_relative "../rewrite_assumptions"
require_relative "catalog/calls"
require_relative "catalog/standalone"
require_relative "catalog/types"

module Quaack
  module Enclave
    module RewriteRules
      # The catalog facts a rule may rely on (DESIGN.md's rewrite-rules). A rule states
      # each fact as an assumption in assumption-check's vocabulary (see
      # RewriteAssumptions) and asks whether the catalog proves it:
      #
      #   catalog = Catalog.new(connection)
      #   catalog.met?("kind" => "not_null", "table" => "public.orders", "column" => "id")   # => true
      #
      # That's assumption-check's own AssumptionCheck, so a rule fires on exactly the
      # facts assumption-check will accept when it checks the rewrite again. An
      # assumption the vocabulary can't state, such as one on a table whose
      # name has a space, is never met. Each answer is kept for the life of
      # the Catalog. connection is read only, as AssumptionCheck reads it.
      #
      # It also lists a table's columns, in the table's order, for a rule
      # that writes a UNION, and just their names, which is what a star in a
      # select list stands for, and the tables a column's foreign keys
      # point at:
      #
      #   catalog.columns("public", "orders")        # => [Column(name: "id", comparable: true), ...]
      #   catalog.column_names("public", "orders")   # => ["id", "customer_id", "total"]
      #   catalog.referenced_tables("public", "orders", "customer_id")   # => ["customers"]
      #
      # comparable says UNION can tell two of the column's values apart as
      # the column's own equality does: its type is an enum or one of
      # COMPARABLE, the built-in types known to hash and sort, and its
      # collation, if it has one, is deterministic. That isn't one of assumption-check's
      # facts, and no rewrite's rows depend on it: a UNION over a type with
      # no equality, such as json, is an error, not other rows. A table
      # that doesn't exist has no columns.
      #
      # For a rule that moves a subquery, it says whether one SELECT stands
      # on its own and whether it might call a volatile function:
      #
      #   catalog.self_contained?("SELECT o.id FROM public.orders o WHERE o.total > $1")   # => true
      #   catalog.calls_volatile?("SELECT random()")                                       # => true
      #
      # For a rule that moves an expression past a join, it says whether
      # each of its calls gives one value per row (see Calls):
      #
      #   catalog.row_wise?([lower_call_node])     # => true
      #   catalog.row_wise?([unnest_call_node])    # => false
      #
      # It also names a type written in a cast as column_info names a
      # column's (see Types).
      class Catalog
        include Standalone
        include Calls
        include Types

        Column = Data.define(:name, :comparable)
        Info = Data.define(:type, :collation, :deterministic)

        COMPARABLE = %w[bool int2 int4 int8 oid float4 float8 numeric text varchar bpchar name uuid date time timetz
                        timestamp timestamptz interval bytea].freeze

        # A dropped column has no type, so the join to pg_type leaves it out.
        COLUMNS = <<~SQL.freeze
          SELECT a.attname,
                 (t.typtype = 'e' OR (n.nspname = 'pg_catalog' AND t.typname = ANY ($3::text[])))
                 AND (a.attcollation = 0 OR co.collisdeterministic)
          FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
          JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
          LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
          WHERE a.attrelid = #{AssumptionCheck::RELATION} AND a.attnum > 0
          ORDER BY a.attnum
        SQL

        COLUMN_INFO = <<~SQL.freeze
          SELECT pg_catalog.format_type(a.atttypid, a.atttypmod) AS type,
                 CASE WHEN a.attcollation = 0 THEN NULL
                      ELSE pg_catalog.format('%I.%I', cn.nspname, co.collname)
                 END AS collation,
                 a.attcollation = 0 OR co.collisdeterministic AS deterministic
          FROM pg_catalog.pg_attribute a
          LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
          LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
          WHERE a.attrelid = #{AssumptionCheck::RELATION} AND a.attname = $3 AND a.attnum > 0
        SQL

        # The column type's default btree operator family: the type's own
        # default btree opclass, or failing that the one opclass of a
        # preferred type it coerces to without a function, as varchar does to
        # text, which is how Postgres picks varchar's =. A domain, an enum, or
        # an array has neither, so it has none.
        BTREE_FAMILY = <<~SQL.freeze
          WITH col AS (
            SELECT a.atttypid AS type FROM pg_catalog.pg_attribute a
            WHERE a.attrelid = #{AssumptionCheck::RELATION} AND a.attname = $3 AND a.attnum > 0
          ), opclasses AS (
            SELECT c.opcfamily, c.opcintype, c.opcintype = col.type AS exact, t.typispreferred AS preferred
            FROM col
            JOIN pg_catalog.pg_opclass c ON c.opcdefault
            JOIN pg_catalog.pg_am am ON am.oid = c.opcmethod AND am.amname = 'btree'
            JOIN pg_catalog.pg_type t ON t.oid = c.opcintype
            WHERE c.opcintype = col.type
               OR EXISTS (SELECT 1 FROM pg_catalog.pg_cast k
                          WHERE k.castsource = col.type AND k.casttarget = c.opcintype AND k.castmethod = 'b')
          )
          SELECT o.opcfamily, col.type FROM opclasses o, col
          WHERE o.exact OR (o.preferred AND NOT EXISTS (SELECT 1 FROM opclasses e WHERE e.exact))
        SQL

        # How many operators named =, <, <=, >, or >= between two of the
        # column's type ($2) aren't in the family ($1) under that name.
        # Postgres picks an operator taking exactly the column's type over
        # any other.
        BTREE_OPERATORS = <<~SQL
          WITH strategies (strategy, name) AS (VALUES (1, '<'), (2, '<='), (3, '='), (4, '>='), (5, '>'))
          SELECT count(*) FROM strategies s
          JOIN pg_catalog.pg_operator op ON op.oprname = s.name AND op.oprleft = $2 AND op.oprright = $2
          WHERE NOT EXISTS (SELECT 1 FROM pg_catalog.pg_amop o
                            WHERE o.amopfamily = $1 AND o.amopopr = op.oid AND o.amopstrategy = s.strategy)
        SQL

        # The tables any foreign key from the column points at, NOT VALID
        # ones included.
        REFERENCED = <<~SQL.freeze
          SELECT DISTINCT r.relname FROM pg_catalog.pg_constraint c
          JOIN pg_catalog.pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = ANY (c.conkey)
          JOIN pg_catalog.pg_class r ON r.oid = c.confrelid
          WHERE c.conrelid = #{AssumptionCheck::RELATION} AND c.contype = 'f' AND a.attname = $3
          ORDER BY 1
        SQL

        def initialize(connection)
          @connection = connection
          @met = {}
          @columns = {}
          @column_info = {}
          @default_btree = {}
        end

        # Whether =, <, <=, >, and >= between two values of the column's type
        # are the operators of its default btree family, so values that = calls
        # equal compare alike under all five.
        def default_btree?(schema, table, column)
          @default_btree.fetch([schema, table, column]) do
            @default_btree[[schema, table, column]] = default_btree_family?(schema, table, column)
          end
        end

        def columns(schema, table)
          @columns[[schema, table]] ||=
            @connection.exec_params(COLUMNS, [schema, table, "{#{COMPARABLE.join(",")}}"]).values
                       .map { |name, comparable| Column.new(name:, comparable: comparable == "t") }
        end

        def column_names(schema, table) = columns(schema, table).map(&:name)

        # The names of the tables a foreign key from the column points at.
        def referenced_tables(schema, table, column)
          @connection.exec_params(REFERENCED, [schema, table, column]).column_values(0)
        end

        def column_info(schema, table, column)
          @column_info[[schema, table, column]] ||= begin
            row = @connection.exec_params(COLUMN_INFO, [schema, table, column]).first
            Info.new(type: row["type"], collation: row["collation"], deterministic: row["deterministic"] == "t") if row
          end
        end

        def met?(assumption)
          @met.fetch(assumption) do
            @met[assumption] = RewriteAssumptions.assumption?(assumption) &&
                               AssumptionCheck.met?(assumption, @connection)
          end
        end

        private

        def default_btree_family?(schema, table, column)
          families = @connection.exec_params(BTREE_FAMILY, [schema, table, column]).values
          return false unless families.size == 1

          @connection.exec_params(BTREE_OPERATORS, families.first).getvalue(0, 0) == "0"
        end
      end
    end
  end
end
