# frozen_string_literal: true

module Quaack
  module Enclave
    # IndexBuild's catalog SQL, in its own file for length. Every name is
    # pg_catalog's, so nothing planted ahead of it on the search_path can
    # change what it finds or updates.
    module IndexBuild
      SIZE_SQL = "SELECT pg_catalog.pg_relation_size($1::pg_catalog.oid)"

      # The oid of the index in schema $1 named $2.
      OID_SQL = <<~SQL
        SELECT c.oid FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        WHERE n.nspname OPERATOR(pg_catalog.=) $1 AND c.relname OPERATOR(pg_catalog.=) $2
          AND c.relkind OPERATOR(pg_catalog.=) 'i'
      SQL

      # Sets indisvalid to $1 for each QUAACK index whose schema is in $2
      # and name, at the same place, in $3.
      SET_VALID_SQL = <<~SQL
        UPDATE pg_catalog.pg_index i SET indisvalid = $1 FROM pg_catalog.pg_class c, pg_catalog.pg_namespace n
        WHERE c.oid OPERATOR(pg_catalog.=) i.indexrelid AND n.oid OPERATOR(pg_catalog.=) c.relnamespace
          AND (n.nspname, c.relname) OPERATOR(pg_catalog.=) ANY (
            SELECT * FROM ROWS FROM (pg_catalog.unnest($2::pg_catalog.text[]), pg_catalog.unnest($3::pg_catalog.text[])))
          AND c.relname OPERATOR(pg_catalog.~~) 'quaack\\_%'
          AND NOT i.indisunique AND NOT i.indisprimary AND NOT i.indisexclusion
      SQL

      # The names of the valid indexes whose schema is in $1 and name, at
      # the same place, in $2. ROWS FROM, since only an unqualified unnest
      # takes several arrays.
      VALID_NAMES_SQL = <<~SQL
        SELECT c.relname FROM pg_catalog.pg_index i
        JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) i.indexrelid
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        WHERE (n.nspname, c.relname) OPERATOR(pg_catalog.=) ANY (
            SELECT * FROM ROWS FROM (pg_catalog.unnest($1::pg_catalog.text[]), pg_catalog.unnest($2::pg_catalog.text[])))
          AND i.indisvalid
        ORDER BY c.relname
      SQL
    end
  end
end
