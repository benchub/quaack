# frozen_string_literal: true

module Quaack
  module Enclave
    module PlannerStatistics
      # The statistics a role that doesn't own a table can't see, even with
      # SELECT on every column (DESIGN.md's statistics). Each is found from
      # the catalog by the condition the view that hides it uses, so none of
      # this needs access to pg_statistic or pg_statistic_ext_data. Every
      # comparison names pg_catalog's operator, as Catalog's do.
      #
      # - An expression index's pg_stats rows: pg_stats shows an index's
      #   columns only to a role with SELECT on them, and an index has no
      #   privileges of its own, so only its owner has it. A plain index has
      #   no statistics of its own to hide.
      # - An extended statistics object's pg_stats_ext data: pg_stats_ext
      #   shows it only to a member of the table owner's role, and, with row
      #   security active, to no one. A hidden object that ANALYZE filled
      #   looks the same as one it hasn't, so both count as hidden.
      # - Every column's pg_stats row, when row security is active for the
      #   role. That refuses as row_security_statistics_hidden.
      module Hidden
        INDEXES_SQL = <<~SQL
          SELECT c.relname FROM pg_catalog.pg_index i
          JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) i.indexrelid
          WHERE i.indrelid OPERATOR(pg_catalog.=) $1 AND i.indisvalid AND i.indexprs IS NOT NULL
           AND EXISTS (SELECT FROM pg_catalog.pg_attribute a
                       WHERE a.attrelid OPERATOR(pg_catalog.=) i.indexrelid AND a.attnum OPERATOR(pg_catalog.>) 0
                        AND NOT pg_catalog.has_column_privilege(i.indexrelid, a.attnum, 'SELECT'))
          ORDER BY c.relname COLLATE pg_catalog."C"
        SQL

        EXTENDED_SQL = <<~SQL
          SELECT n.nspname, s.stxname FROM pg_catalog.pg_statistic_ext s
          JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) s.stxnamespace
          JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) s.stxrelid
          WHERE s.stxrelid OPERATOR(pg_catalog.=) $1
           AND (NOT pg_catalog.pg_has_role(c.relowner, 'USAGE')
                OR (c.relrowsecurity AND pg_catalog.row_security_active(c.oid)))
          ORDER BY n.nspname COLLATE pg_catalog."C", s.stxname COLLATE pg_catalog."C"
        SQL

        # Whether row security is active for the role on the table. A role
        # that owns the table, or has BYPASSRLS, is exempt, unless the
        # table forces row security on its owner.
        ROW_SECURITY_SQL = <<~SQL
          SELECT c.relrowsecurity AND pg_catalog.row_security_active(c.oid)
          FROM pg_catalog.pg_class c WHERE c.oid OPERATOR(pg_catalog.=) $1
        SQL

        module_function

        # The names, never the data, of the hidden expression indexes and
        # extended statistics objects ("schema.name"), each sorted.
        def read(connection, oid)
          { "indexes" => connection.exec_params(INDEXES_SQL, [oid]).column_values(0),
            "extended_statistics" => connection.exec_params(EXTENDED_SQL, [oid]).values.map { it.join(".") } }
        end

        # Refuses when row security hides every column's statistics: it's
        # active for the role, and pg_stats showed none of entry's columns.
        def check_row_security!(table, oid, entry, connection)
          return unless entry["columns"].empty?
          return unless connection.exec_params(ROW_SECURITY_SQL, [oid]).getvalue(0, 0) == "t"

          raise Error.new("row_security_statistics_hidden", "row security hides the column statistics of #{table}")
        end
      end
    end
  end
end
