# frozen_string_literal: true

require "pg"

module Quaack
  module Enclave
    module AssumptionCheck
      # The = to compare two user columns with, as the application's query
      # compares them, found in the catalog rather than on the search path,
      # so an operator planted ahead of the type's own can't stand in:
      #
      #   Equality.operator(connection, left_type, right_type)   # => "OPERATOR(public.=)", or nil
      #
      # It's the equality (strategy 3) of the left type's default btree
      # operator family, taking the two types' btree input types. A domain
      # counts as its base type, an enum as anyenum, and a type with no
      # default btree opclass of its own, such as varchar, as the one
      # preferred type it coerces to without a function, as Postgres picks
      # text's = for varchar. citext's = is then citext's own, not text's,
      # which its implicit cast to text would give pg_catalog.=. nil when
      # there's no such operator: the comparison can't be shown to be the
      # application's. An array, range, multirange, or composite type's
      # default opclass takes a polymorphic type (anyarray, anyrange,
      # anymultirange, record), whose = is the application's only when
      # both sides have exactly the same type, so it's taken only then. When
      # the = is one for other types than the columns' own, as these all
      # are, an = taking the columns' types exactly in more places than it
      # does, even on one side, in any schema, is what a bare = would pick
      # instead, so it's nil then too.
      module Equality
        ANYENUM = 3500
        # The polymorphic btree input type of a true array, then by typtype.
        ANYARRAY = 2277
        POLYMORPHIC = { "r" => 3831, "m" => 4537, "c" => 2249 }.freeze
        OPERATOR_NAME = %r{\A[-+*/<>=~!@#%^&|`?]+\z}

        TYPE_SQL = <<~SQL
          SELECT t.typtype, t.typbasetype, pg_catalog.quote_ident(n.nspname), pg_catalog.quote_ident(t.typname),
                 t.typsubscript::pg_catalog.oid OPERATOR(pg_catalog.=)
                   'pg_catalog.array_subscript_handler'::pg_catalog.regproc::pg_catalog.oid
          FROM pg_catalog.pg_type t JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) t.typnamespace
          WHERE t.oid OPERATOR(pg_catalog.=) $1
        SQL

        # The column's type, or none for a column that isn't there. $1 is
        # the table as the query names it.
        COLUMN_SQL = <<~SQL
          SELECT a.atttypid FROM pg_catalog.pg_attribute a
          WHERE a.attrelid OPERATOR(pg_catalog.=) pg_catalog.to_regclass($1)
            AND a.attname OPERATOR(pg_catalog.=) $2 AND a.attnum OPERATOR(pg_catalog.>) 0 AND NOT a.attisdropped
        SQL

        # Default btree opclasses for the type ($1): its own, then the
        # preferred ones it coerces to without a function.
        BTREE_TYPE_SQL = <<~SQL
          SELECT c.opcintype, c.opcintype OPERATOR(pg_catalog.=) $1 AS exact
          FROM pg_catalog.pg_opclass c
          JOIN pg_catalog.pg_am am ON am.oid OPERATOR(pg_catalog.=) c.opcmethod AND am.amname OPERATOR(pg_catalog.=) 'btree'
          JOIN pg_catalog.pg_type t ON t.oid OPERATOR(pg_catalog.=) c.opcintype
          WHERE c.opcdefault AND (c.opcintype OPERATOR(pg_catalog.=) $1 OR (t.typispreferred AND EXISTS (
            SELECT 1 FROM pg_catalog.pg_cast k
            WHERE k.castsource OPERATOR(pg_catalog.=) $1 AND k.casttarget OPERATOR(pg_catalog.=) c.opcintype
              AND k.castmethod OPERATOR(pg_catalog.=) 'b')))
        SQL

        EQUALITY_SQL = <<~SQL
          SELECT pg_catalog.quote_ident(n.nspname), op.oprname
          FROM pg_catalog.pg_opclass c
          JOIN pg_catalog.pg_am am ON am.oid OPERATOR(pg_catalog.=) c.opcmethod AND am.amname OPERATOR(pg_catalog.=) 'btree'
          JOIN pg_catalog.pg_amop o ON o.amopfamily OPERATOR(pg_catalog.=) c.opcfamily
          JOIN pg_catalog.pg_operator op ON op.oid OPERATOR(pg_catalog.=) o.amopopr
          JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) op.oprnamespace
          WHERE c.opcdefault AND c.opcintype OPERATOR(pg_catalog.=) $1 AND o.amopstrategy OPERATOR(pg_catalog.=) 3
            AND o.amoplefttype OPERATOR(pg_catalog.=) $1 AND o.amoprighttype OPERATOR(pg_catalog.=) $2
        SQL

        # Whether an =, in any schema, takes the two types ($1, $2) exactly
        # in more places than the family's = does ($3, 0 to 2).
        EXACT_SQL = <<~SQL
          SELECT EXISTS (
            SELECT 1 FROM pg_catalog.pg_operator op
            WHERE op.oprname OPERATOR(pg_catalog.=) '='
              AND (op.oprleft OPERATOR(pg_catalog.=) $1)::pg_catalog.int4
                  OPERATOR(pg_catalog.+) (op.oprright OPERATOR(pg_catalog.=) $2)::pg_catalog.int4
                  OPERATOR(pg_catalog.>) $3::pg_catalog.int4)
        SQL

        module_function

        # The type oid of table's column, or nil.
        def column_type(connection, table, column)
          connection.exec_params(COLUMN_SQL, [table, column]).values.dig(0, 0)&.then { Integer(it) }
        end

        # [base type oid, its schema-qualified, quoted name], following
        # domains down to their base type.
        def base(connection, type)
          loop do
            kind, base, schema, name = connection.exec_params(TYPE_SQL, [type]).values.first
            return [type, "#{schema}.#{name}"] unless kind == "d"

            type = Integer(base)
          end
        end

        # The = between values of left and right, both base type oids, or
        # nil.
        def operator(connection, left, right)
          inputs = input_types(connection, left, right) or return

          rows = connection.exec_params(EQUALITY_SQL, inputs).values
          schema, name = rows.first
          "OPERATOR(#{schema}.#{name})" if rows.size == 1 && name.match?(OPERATOR_NAME)
        end

        # The btree input types whose = compares left and right, or nil.
        def input_types(connection, left, right)
          left_in = btree_type(connection, left)
          right_in = btree_type(connection, right)
          left_in = right_in = polymorphic(connection, left) if left == right && !left_in
          return unless left_in && right_in

          [left_in, right_in] unless shadowed?(connection, [left, right], [left_in, right_in])
        end

        # Whether an = matches the types exactly in more places than the
        # family's, which takes others, such as anyenum, record, or text for
        # varchar: Postgres prefers the candidate with the most exact
        # matches, so a bare = picks it, even when it's exact on one side.
        def shadowed?(connection, types, inputs)
          exact = types.zip(inputs).count { |type, input| type == input }
          connection.exec_params(EXACT_SQL, [*types, exact]).values.dig(0, 0) == "t"
        end

        # The polymorphic type a type's default opclass takes, or nil.
        def polymorphic(connection, type)
          kind, *, array = connection.exec_params(TYPE_SQL, [type]).values.first
          array == "t" ? ANYARRAY : POLYMORPHIC[kind]
        end

        def btree_type(connection, type)
          return ANYENUM if connection.exec_params(TYPE_SQL, [type]).values.dig(0, 0) == "e"

          rows = connection.exec_params(BTREE_TYPE_SQL, [type]).values
          exact = rows.find { it[1] == "t" }
          return Integer(exact[0]) if exact

          Integer(rows.first[0]) if rows.size == 1
        end
      end
    end
  end
end
