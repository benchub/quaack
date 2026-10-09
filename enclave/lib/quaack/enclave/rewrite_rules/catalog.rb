# frozen_string_literal: true

require_relative "../assumption_check"
require_relative "../rewrite_assumptions"
require_relative "catalog/btree"
require_relative "catalog/calls"
require_relative "catalog/foreign_keys"
require_relative "catalog/keys"
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
        include Btree
        include Calls
        include ForeignKeys
        include Keys
        include Types

        Column = Data.define(:name, :comparable)
        # type has the typmod, as character varying(10); base_type hasn't,
        # as character varying.
        Info = Data.define(:type, :base_type, :collation, :deterministic)

        COMPARABLE = %w[bool int2 int4 int8 oid float4 float8 numeric text varchar bpchar name uuid date time timetz
                        timestamp timestamptz interval bytea].freeze

        EQ = "OPERATOR(pg_catalog.=)"

        # A dropped column has no type, so the join to pg_type leaves it out.
        COLUMNS = <<~SQL.freeze
          SELECT a.attname,
                 (t.typtype #{EQ} 'e'
                  OR (n.nspname #{EQ} 'pg_catalog' AND t.typname #{EQ} ANY ($3::pg_catalog.text[])))
                 AND (a.attcollation #{EQ} 0 OR co.collisdeterministic)
          FROM pg_catalog.pg_attribute a
          JOIN pg_catalog.pg_type t ON t.oid #{EQ} a.atttypid
          JOIN pg_catalog.pg_namespace n ON n.oid #{EQ} t.typnamespace
          LEFT JOIN pg_catalog.pg_collation co ON co.oid #{EQ} a.attcollation
          WHERE a.attrelid #{EQ} #{AssumptionCheck::RELATION} AND a.attnum OPERATOR(pg_catalog.>) 0
          ORDER BY a.attnum
        SQL

        COLUMN_INFO = <<~SQL.freeze
          SELECT pg_catalog.format_type(a.atttypid, a.atttypmod) AS type,
                 pg_catalog.format_type(a.atttypid, NULL) AS base_type,
                 CASE WHEN a.attcollation #{EQ} 0 THEN NULL
                      ELSE pg_catalog.format('%I.%I', cn.nspname, co.collname)
                 END AS collation,
                 a.attcollation #{EQ} 0 OR co.collisdeterministic AS deterministic
          FROM pg_catalog.pg_attribute a
          LEFT JOIN pg_catalog.pg_collation co ON co.oid #{EQ} a.attcollation
          LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid #{EQ} co.collnamespace
          WHERE a.attrelid #{EQ} #{AssumptionCheck::RELATION} AND a.attname #{EQ} $3 AND a.attnum OPERATOR(pg_catalog.>) 0
        SQL

        # The tables any foreign key from the column points at, NOT VALID
        # ones included.
        REFERENCED = <<~SQL.freeze
          SELECT DISTINCT r.relname FROM pg_catalog.pg_constraint c
          JOIN pg_catalog.pg_attribute a ON a.attrelid #{EQ} c.conrelid AND a.attnum #{EQ} ANY (c.conkey)
          JOIN pg_catalog.pg_class r ON r.oid #{EQ} c.confrelid
          WHERE c.conrelid #{EQ} #{AssumptionCheck::RELATION} AND c.contype #{EQ} 'f' AND a.attname #{EQ} $3
          ORDER BY 1
        SQL

        NONDETERMINISTIC = <<~SQL.freeze
          SELECT EXISTS (
            SELECT FROM pg_catalog.pg_collation c
            WHERE NOT c.collisdeterministic
              AND (c.oid #{EQ} ANY (SELECT attcollation FROM pg_catalog.pg_attribute WHERE NOT attisdropped)
                OR c.oid #{EQ} ANY (SELECT typcollation FROM pg_catalog.pg_type)
                OR c.oid #{EQ} ANY (SELECT rngcollation FROM pg_catalog.pg_range)))
        SQL

        def initialize(connection)
          @connection = connection
          @met = {}
          @columns = {}
          @column_info = {}
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
            if row
              Info.new(type: row["type"], base_type: row["base_type"], collation: row["collation"],
                       deterministic: row["deterministic"] == "t")
            end
          end
        end

        # Whether the connection reads a string constant's backslashes as
        # pg_query does: standard_conforming_strings is on.
        def standard_strings?
          @standard_strings = @connection.exec("SHOW standard_conforming_strings").getvalue(0, 0) == "on" if
            @standard_strings.nil?
          @standard_strings
        end

        # Whether a column, domain, or range in the database uses a
        # nondeterministic collation. A dropped column doesn't count.
        def nondeterministic_collations?
          @nondeterministic = @connection.exec(NONDETERMINISTIC).getvalue(0, 0) == "t" if @nondeterministic.nil?
          @nondeterministic
        end

        def met?(assumption)
          @met.fetch(assumption) do
            @met[assumption] = RewriteAssumptions.assumption?(assumption) &&
                               AssumptionCheck.met?(assumption, @connection)
          end
        end
      end
    end
  end
end
