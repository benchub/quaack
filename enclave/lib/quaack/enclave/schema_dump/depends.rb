# frozen_string_literal: true

require "json"
require_relative "../error_filter/named_tables"

module Quaack
  module Enclave
    module SchemaDump
      # The objects the dumped namespaces depend on (DESIGN.md's
      # schema-dump), by pg_depend. Postgres records what a column default,
      # a view, a constraint, or a SQL function with a BEGIN ATOMIC body
      # uses, but not what a function with a string body does, so the
      # operator names those schemas in extra_dump_schemas.
      module Depends # rubocop:disable Metrics/ModuleLength
        # The relation kinds pg_dump's --exclude-table leaves out: tables,
        # partitioned tables, views, materialized views, sequences, and
        # foreign tables. A composite type is a type, so it stays.
        RELKINDS = "'{r,p,v,m,S,f}'::pg_catalog.\"char\"[]"

        # Every object outside the namespaces in $1 (a JSON array of names)
        # that the objects in them depend on, by pg_depend, at any depth, as
        # its namespace and, for a relation of RELKINDS, its name. The walk
        # also starts from every object but such a relation in the namespaces
        # in $2, the ones an earlier pass added, since pg_dump dumps those
        # whole. Each object is taken as its home: a column default,
        # constraint, trigger, rule, index, or row type as its table's, a
        # domain's constraint as its domain's, and an array type as its
        # element's. A system schema's objects are never followed or listed.
        # An internal trigger, such as a foreign key's on its parent table, is
        # left out: it's part of its constraint, whose home is the child, so
        # following it would lead from the parent to the child.
        DEPENDS_SQL = <<~SQL.freeze
          WITH RECURSIVE raw (classid, objid, hclass, hobj, nsp) AS (
            SELECT 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid, c.oid,
                   'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid, COALESCE(i.indrelid, c.oid), c.relnamespace
            FROM pg_catalog.pg_class c LEFT JOIN pg_catalog.pg_index i ON i.indexrelid OPERATOR(pg_catalog.=) c.oid
            UNION ALL
            SELECT 'pg_catalog.pg_type'::pg_catalog.regclass::pg_catalog.oid, t.oid,
                   (CASE WHEN b.typrelid OPERATOR(pg_catalog.<>) 0 THEN 'pg_catalog.pg_class'::pg_catalog.regclass
                         ELSE 'pg_catalog.pg_type'::pg_catalog.regclass END)::pg_catalog.oid,
                   CASE WHEN b.typrelid OPERATOR(pg_catalog.<>) 0 THEN b.typrelid ELSE b.oid END, t.typnamespace
            FROM pg_catalog.pg_type t
            LEFT JOIN pg_catalog.pg_type e ON e.typarray OPERATOR(pg_catalog.=) t.oid
            CROSS JOIN LATERAL (SELECT COALESCE(e.oid, t.oid) AS oid, COALESCE(e.typrelid, t.typrelid) AS typrelid) b
            UNION ALL
            SELECT 'pg_catalog.pg_proc'::pg_catalog.regclass::pg_catalog.oid, p.oid,
                   'pg_catalog.pg_proc'::pg_catalog.regclass::pg_catalog.oid, p.oid, p.pronamespace
            FROM pg_catalog.pg_proc p
            UNION ALL
            SELECT 'pg_catalog.pg_operator'::pg_catalog.regclass::pg_catalog.oid, o.oid,
                   'pg_catalog.pg_operator'::pg_catalog.regclass::pg_catalog.oid, o.oid, o.oprnamespace
            FROM pg_catalog.pg_operator o
            UNION ALL
            SELECT 'pg_catalog.pg_collation'::pg_catalog.regclass::pg_catalog.oid, l.oid,
                   'pg_catalog.pg_collation'::pg_catalog.regclass::pg_catalog.oid, l.oid, l.collnamespace
            FROM pg_catalog.pg_collation l
            UNION ALL
            SELECT 'pg_catalog.pg_constraint'::pg_catalog.regclass::pg_catalog.oid, k.oid,
                   (CASE WHEN k.conrelid OPERATOR(pg_catalog.<>) 0 THEN 'pg_catalog.pg_class'::pg_catalog.regclass
                         WHEN k.contypid OPERATOR(pg_catalog.<>) 0 THEN 'pg_catalog.pg_type'::pg_catalog.regclass
                         ELSE 'pg_catalog.pg_constraint'::pg_catalog.regclass END)::pg_catalog.oid,
                   CASE WHEN k.conrelid OPERATOR(pg_catalog.<>) 0 THEN k.conrelid
                        WHEN k.contypid OPERATOR(pg_catalog.<>) 0 THEN k.contypid ELSE k.oid END,
                   k.connamespace
            FROM pg_catalog.pg_constraint k
            UNION ALL
            SELECT 'pg_catalog.pg_attrdef'::pg_catalog.regclass::pg_catalog.oid, d.oid,
                   'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid, d.adrelid, c.relnamespace
            FROM pg_catalog.pg_attrdef d JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) d.adrelid
            UNION ALL
            SELECT 'pg_catalog.pg_trigger'::pg_catalog.regclass::pg_catalog.oid, g.oid,
                   'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid, g.tgrelid, c.relnamespace
            FROM pg_catalog.pg_trigger g JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) g.tgrelid
            WHERE NOT g.tgisinternal
            UNION ALL
            SELECT 'pg_catalog.pg_rewrite'::pg_catalog.regclass::pg_catalog.oid, w.oid,
                   'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid, w.ev_class, c.relnamespace
            FROM pg_catalog.pg_rewrite w JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) w.ev_class
            UNION ALL
            SELECT 'pg_catalog.pg_policy'::pg_catalog.regclass::pg_catalog.oid, y.oid,
                   'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid, y.polrelid, c.relnamespace
            FROM pg_catalog.pg_policy y JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) y.polrelid
          ), home AS (
            SELECT raw.*, hc.oid IS NOT NULL AS rel, n.nspname,
                   n.nspname OPERATOR(pg_catalog.=) 'information_schema' OR n.nspname OPERATOR(pg_catalog.~) '^pg_' AS system,
                   n.nspname OPERATOR(pg_catalog.=) ANY (SELECT pg_catalog.json_array_elements_text($1::pg_catalog.json))
                     AS dumped
            FROM raw
            JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) raw.nsp
            LEFT JOIN pg_catalog.pg_class hc
              ON raw.hclass OPERATOR(pg_catalog.=) 'pg_catalog.pg_class'::pg_catalog.regclass::pg_catalog.oid
             AND hc.oid OPERATOR(pg_catalog.=) raw.hobj AND hc.relkind OPERATOR(pg_catalog.=) ANY (#{RELKINDS})
          ), reach (hclass, hobj) AS (
            SELECT hclass, hobj FROM home
            WHERE dumped
               OR (NOT rel AND nspname OPERATOR(pg_catalog.=)
                     ANY (SELECT pg_catalog.json_array_elements_text($2::pg_catalog.json)))
            UNION
            SELECT r.hclass, r.hobj
            FROM reach
            JOIN home d ON d.hclass OPERATOR(pg_catalog.=) reach.hclass AND d.hobj OPERATOR(pg_catalog.=) reach.hobj
            JOIN pg_catalog.pg_depend dep
              ON dep.classid OPERATOR(pg_catalog.=) d.classid AND dep.objid OPERATOR(pg_catalog.=) d.objid
            JOIN home r ON r.classid OPERATOR(pg_catalog.=) dep.refclassid AND r.objid OPERATOR(pg_catalog.=) dep.refobjid
            WHERE dep.deptype OPERATOR(pg_catalog.=) ANY ('{n,a,i}'::pg_catalog."char"[]) AND NOT r.system
          )
          SELECT DISTINCT h.nspname, c.relname
          FROM reach
          JOIN home h ON h.classid OPERATOR(pg_catalog.=) reach.hclass AND h.objid OPERATOR(pg_catalog.=) reach.hobj
          LEFT JOIN pg_catalog.pg_class c ON h.rel AND c.oid OPERATOR(pg_catalog.=) reach.hobj
          WHERE NOT h.dumped AND NOT h.system
        SQL

        # Every relation of RELKINDS in the namespaces in $1, a JSON array of
        # names: its namespace, its name, whether pg_dump locks it (a table
        # or a partitioned table), and whether the role can read it, which
        # takes USAGE on its schema and SELECT on it.
        RELATIONS_SQL = <<~SQL.freeze
          SELECT n.nspname, c.relname, c.relkind OPERATOR(pg_catalog.=) ANY ('{r,p}'::pg_catalog."char"[]),
                 pg_catalog.has_schema_privilege(n.oid, 'USAGE') AND pg_catalog.has_table_privilege(c.oid, 'SELECT')
          FROM pg_catalog.pg_class c
          JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
          WHERE c.relkind OPERATOR(pg_catalog.=) ANY (#{RELKINDS})
            AND n.nspname OPERATOR(pg_catalog.=) ANY (SELECT pg_catalog.json_array_elements_text($1::pg_catalog.json))
          ORDER BY n.nspname COLLATE "C", c.relname COLLATE "C"
        SQL

        module_function

        # The namespaces to add, sorted, and the relations of theirs that
        # nothing needs, as [schema, name] pairs. A pass that adds a
        # namespace walks again from all of it but its relations, since
        # pg_dump dumps those whole, until a pass adds nothing new.
        def added(connection, whole)
          added = []
          loop do
            rows = connection.exec_params(DEPENDS_SQL, [JSON.generate(whole), JSON.generate(added)]).values
            rows = rows.map { |row| row.map { SchemaDump.utf8(it) if it } }
            found = rows.map(&:first).uniq.sort
            next added = found unless found == added

            return [added, excluded(connection, added, rows.filter_map { |schema, name| [schema, name] if name })]
          end
        end

        def excluded(connection, added, needed)
          relations(connection, added).map { it.first(2) } - needed
        end

        # Refuses with dump_object_unreadable if the role can't read a table
        # pg_dump will lock: one in namespaces that isn't excluded.
        def readable!(connection, namespaces, excluded)
          unreadable = relations(connection, namespaces).filter_map do |schema, name, locked, readable|
            "#{schema}.#{name}" if locked && !readable && !excluded.include?([schema, name])
          end
          return if unreadable.empty?

          count = unreadable.size
          raise Error.new("dump_object_unreadable",
                          "the role can't read #{count} #{count == 1 ? "table" : "tables"} the dump needs",
                          tables: unreadable.first(ErrorFilter::Tables::SIZES.max))
        end

        def relations(connection, namespaces)
          connection.exec_params(RELATIONS_SQL, [JSON.generate(namespaces)]).values.map do |schema, name, locked, ok|
            [SchemaDump.utf8(schema), SchemaDump.utf8(name), locked == "t", ok == "t"]
          end
        end
      end
    end
  end
end
