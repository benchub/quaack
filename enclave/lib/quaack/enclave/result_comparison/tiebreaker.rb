# frozen_string_literal: true

require_relative "../result_comparator"

module Quaack
  module Enclave
    module ResultComparison
      # Which output columns fixture-compare's tiebreaker can sort by, and the
      # catalog checks around it. ResultComparison (result_comparison.rb)
      # says how the tiebreaker is used and why these rules keep it sound.
      module Tiebreaker
        # Built-in types that ORDER BY can sort, and their arrays, as [oid,
        # array oid]. result_comparison_postgres_spec.rb checks each one
        # against Postgres.
        ORDERABLE_TYPES = {
          bool: [16, 1000], bytea: [17, 1001], char: [18, 1002], name: [19, 1003], int8: [20, 1016],
          int2: [21, 1005], int4: [23, 1007], text: [25, 1009], oid: [26, 1028], tid: [27, 1010],
          float4: [700, 1021], float8: [701, 1022], money: [790, 791], macaddr8: [774, 775],
          macaddr: [829, 1040], cidr: [650, 651], inet: [869, 1041], bpchar: [1042, 1014],
          varchar: [1043, 1015], date: [1082, 1182], time: [1083, 1183], timestamp: [1114, 1115],
          timestamptz: [1184, 1185], interval: [1186, 1187], timetz: [1266, 1270], bit: [1560, 1561],
          varbit: [1562, 1563], numeric: [1700, 1231], uuid: [2950, 2951], pg_lsn: [3220, 3221],
          tsvector: [3614, 3643], tsquery: [3615, 3645], jsonb: [3802, 3807]
        }.freeze
        ORDERABLE_OIDS = ORDERABLE_TYPES.values.flatten.to_set.freeze

        # A column goes in the tiebreaker only if values btree calls equal
        # are always equal to the comparator too. These break that:
        # - At any level: jsonb ({"a": 1.0} and {"a": 1.00}), which the
        #   comparator reads as text.
        # - Inside an array, range, or composite, also interval, numeric,
        #   float4, float8, and bpchar. The comparator reads those by value,
        #   or without trailing spaces, only as a whole column. Inside a
        #   container it reads the container's text, where {1.0} and {1.00},
        #   or {"1 day"} and {"24:00:00"}, differ.
        UNFAITHFUL = %i[jsonb].freeze
        UNFAITHFUL_INSIDE = [*UNFAITHFUL, :interval, :numeric, :float4, :float8, :bpchar].freeze
        FAITHFUL_ELEMENTS = ORDERABLE_TYPES.except(*UNFAITHFUL_INSIDE)
        # Built-in element types a container may hold.
        FAITHFUL_ELEMENT_OIDS = FAITHFUL_ELEMENTS.values.to_set(&:first).freeze
        TIEBREAKER_OIDS = (ORDERABLE_TYPES.except(*UNFAITHFUL).values.map(&:first) +
                           FAITHFUL_ELEMENTS.values.map(&:last)).to_set.freeze

        # Which of the result's other types (%<types>s) can go in the
        # tiebreaker, from the catalog. Faithful elements are the built-ins
        # in FAITHFUL_ELEMENT_OIDS (%<known>s), enums, and ranges of those
        # built-ins. The query finds enums, those ranges, arrays of either,
        # and composites whose fields are all built-in faithful elements or
        # enums. Postgres sorts those through its polymorphic btree operator
        # classes. A dropped field is skipped. A domain needs nothing here,
        # since a result reports its base type. Everything else is left
        # out: numrange and other ranges of numeric or floats, ranges of
        # enums, multiranges, arrays of composites, and composites with any
        # other field, such as json, numeric, a range, another composite, or
        # a domain.
        CATALOG_ORDERABLE_SQL = <<~SQL
          WITH faithful AS (
            SELECT oid FROM pg_type WHERE typtype = 'e'
            UNION ALL
            SELECT rngtypid FROM pg_range WHERE rngsubtype IN (%<known>s)
          )
          SELECT t.oid::int
          FROM pg_type t
          WHERE t.oid IN (%<types>s)
            AND (t.oid IN (SELECT oid FROM faithful)
              OR t.typelem IN (SELECT oid FROM faithful)
              OR (t.typtype = 'c' AND NOT EXISTS (
                SELECT FROM pg_attribute a
                WHERE a.attrelid = t.typrelid AND NOT a.attisdropped
                  AND a.atttypid NOT IN (%<known>s)
                  AND a.atttypid NOT IN (SELECT oid FROM pg_type WHERE typtype = 'e'))))
        SQL

        # A nondeterministic collation that a column, domain, or range uses, or that
        # a COLLATE clause in either query names (%<names>s). Text it
        # compares equal, such as 'a' and 'A', can print differently, and a
        # result can't say which columns use it.
        NONDETERMINISTIC_COLLATION_SQL = <<~SQL
          SELECT count(*)::int FROM pg_collation c
          WHERE NOT c.collisdeterministic
            AND (c.oid IN (SELECT attcollation FROM pg_attribute)
              OR c.oid IN (SELECT typcollation FROM pg_type)
              OR c.oid IN (SELECT rngcollation FROM pg_range)
              OR c.collname IN (%<names>s))
        SQL

        module_function

        # names are the collations the queries' COLLATE clauses name.
        def nondeterministic_collation?(transaction, names)
          names = names.uniq.map { |name| "'#{name.gsub("'", "''")}'" }
          sql = format(NONDETERMINISTIC_COLLATION_SQL, names: names.empty? ? "NULL" : names.join(", "))
          transaction.query(sql).rows.first.first != "0"
        end

        # Whether two of the result's rows are equal on every tiebreaker
        # column but differ in a column left out of it. The tiebreaker can't
        # split those rows, so they can come back either way, in any query.
        def hidden_differences?(result, positions)
          types = result.types
          kept = positions.map(&:pred)
          left_out = types.each_index.to_a - kept
          result.rows.group_by { |row| values_key(types, row, kept) }.values.any? do |rows|
            rows.any? { |row| !same?(types, rows.first, row, left_out) }
          end
        end

        def values_key(types, row, columns) = columns.map { |i| ResultComparator::Values.value_key(types[i], row[i]) }

        def same?(types, left, right, columns)
          columns.all? { |i| ResultComparator::Values.equal?(types[i], left[i], right[i]) }
        end

        # The type OIDs among types, beyond ORDERABLE_OIDS, that the catalog
        # says ORDER BY can sort (see CATALOG_ORDERABLE_SQL). None are looked
        # up when every type is already known. types come from a Result's
        # ftype, so they're Integers and safe to put in the SQL.
        def catalog_orderable(transaction, types)
          unknown = types.reject { |oid| ORDERABLE_OIDS.include?(oid) }.uniq
          return [] if unknown.empty?

          sql = format(CATALOG_ORDERABLE_SQL, types: unknown.join(", "), known: FAITHFUL_ELEMENT_OIDS.to_a.join(", "))
          transaction.query(sql).rows.map { |(oid)| Integer(oid) }
        end

        # The 1-based positions of the columns whose types are in
        # TIEBREAKER_OIDS or catalog_orderable.
        def positions(types, catalog_orderable = [])
          types.each_index.select { |i| TIEBREAKER_OIDS.include?(types[i]) || catalog_orderable.include?(types[i]) }
               .map { |i| i + 1 }
        end
      end
    end
  end
end
