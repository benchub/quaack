# frozen_string_literal: true

require "json"
require "open3"
require_relative "error_filter"
require_relative "table_name"

module Quaack
  module Enclave
    # DESIGN.md's schema-dump: the schema-only dump of every namespace the query's
    # tables, or their FK ancestors, live in, plus public, and the subset:
    # the query's tables and their whole FK ancestor chain. Both go into the
    # governed store, and nothing here leaves the enclave.
    #
    #   SchemaDump.run(store:, relations: Relations.check(sql, settings, conn).relations,
    #                  connection: conn, conninfo: { host: "db1", dbname: "app" })
    #   # => Result(namespaces: ["public", "sales"], tables: [TableName(public.customers), ...])
    #   store.read("schema_dump")   # => { "namespaces" => [...], "ddl" => "<pg_dump output>" }
    #   store.read("schema_subset") # => { "tables" => [["public", "customers"], ...], "ddl" => "..." }
    #
    # The inputs:
    # - relations: the qualified TableNames from Relations.check, the
    #   query's tables. Their schemas and their FK ancestors' schemas, at
    #   any depth, plus public if the database has it, plus the schema of
    #   each extension but plpgsql, are the namespaces,
    #   less any system schema (pg_catalog, information_schema, or another
    #   pg_ one). The full dump also names each of those extensions, so it
    #   holds their CREATE EXTENSION IF NOT EXISTS, with no version, even
    #   for one that lives in a system schema. The full dump also adds
    #   what those namespaces depend on (Depends).
    # - extra_schemas: the operator's extra_dump_schemas (Config), added
    #   whole to the full dump.
    # - connection: a PG connection to the production database, for the
    #   catalog and the server's version. Only plain SELECTs are run on it,
    #   and its settings, including its client encoding, are left alone.
    # - conninfo: libpq connection parameters for pg_dump, such as host,
    #   port, dbname, user, or service, as a Hash. pg_dump runs with the
    #   operator's own libpq setup on the jump server (PGUSER, ~/.pgpass,
    #   ~/.pg_service.conf), and QUAACK stores no credentials, so a secret
    #   (password, sslpassword, oauth_client_secret, or a dbname that is a
    #   connection string) is refused, as is a key that is not a plain
    #   keyword (bad_conninfo_key): pg_dump's
    #   command line is visible to others on the jump server. Until the
    #   production inventory (20260922-16) lands, the caller passes these in.
    # - pg_dump: the command, as an argv prefix. It's pg_dump on PATH by
    #   default. The specs run the harness container's own pg_dump, with
    #   ["docker", "exec", <container>, "pg_dump"].
    # - lock_wait_timeout: how long pg_dump waits for each table's lock,
    #   LOCK_WAIT_TIMEOUT unless a spec wants a shorter one.
    #
    # The subset's tables come from pg_catalog, not from parsing a dump
    # (see 20260923-1): each FK in pg_constraint, from child to parent, at
    # any depth, each table once, so a cycle or a self-reference ends the
    # walk. The subset is then pg_dump with a --table for each one. No
    # inheritance parent is added. A partitioned table in the chain comes
    # with every partition, at every level: Postgres keeps an FK row in
    # pg_constraint for each partition an FK to a partitioned table
    # reaches, and the walk follows those too. A partition's own FKs, and
    # the ones it inherits, are followed like any table's. A query table
    # that's a partition doesn't bring in its parent.
    #
    # Both dumps run with FLAGS: schema only, no owners or privileges,
    # UTF-8 whatever the database's encoding, and --strict-names, so a
    # table or schema that's gone fails the dump rather than being left
    # out, plus a lock wait timeout. Every name goes in quoted, so pg_dump
    # matches it exactly rather than as a pattern. pg_dump runs from an
    # argv, never a shell.
    #
    # pg_dump refuses a server of a later major version, so pg_dump's must
    # be at least the server's.
    #
    # Refusals raise Error, with a rule and a message naming only the rule
    # and shape: secret_in_conninfo, unknown_relation (a relation the
    # catalog doesn't have), pg_dump_missing (it couldn't be run, or didn't
    # print its version), pg_dump_too_old, dump_object_unreadable (a table
    # the dump needs that the role can't read, checked before pg_dump runs,
    # since pg_dump locks every table it dumps), and pg_dump_failed. pg_dump's
    # stderr carries server messages, which can quote values, and names
    # what it was asked for, so it's never read: pg_dump_failed says only
    # the exit status. So a lock wait that timed out is pg_dump_failed too,
    # since pg_dump exits 1 for that as for any other failure. A refusal
    # stores nothing.
    module SchemaDump
      class Error < StandardError
        attr_reader :rule, :tables

        # tables is for dump_object_unreadable: the tables the role can't
        # read, as schema.name Strings, which ErrorFilter sends only to the
        # operator, if each is of its shape.
        def initialize(rule, detail, tables: nil)
          @rule = rule
          @tables = tables
          super("#{rule}: #{detail}")
        end
      end

      Result = Data.define(:namespaces, :tables)

      # The tables named in $1, a JSON array of {"schema", "name"} objects,
      # and every table they reach through FKs, child to parent, at any
      # depth, sorted by byte, as Ruby sorts the namespaces. The catalog's
      # name columns already sort that way, and COLLATE "C" says so. UNION
      # drops a table already found, so a cycle or a self-reference ends the
      # walk rather than looping.
      ANCESTORS_SQL = <<~SQL
        WITH RECURSIVE chain (oid) AS (
          SELECT c.oid
          FROM pg_catalog.json_to_recordset($1::json) AS start (schema pg_catalog.text, name pg_catalog.text)
          JOIN pg_catalog.pg_namespace n ON n.nspname OPERATOR(pg_catalog.=) start.schema
          JOIN pg_catalog.pg_class c
            ON c.relnamespace OPERATOR(pg_catalog.=) n.oid AND c.relname OPERATOR(pg_catalog.=) start.name
          UNION
          SELECT con.confrelid
          FROM chain
          JOIN pg_catalog.pg_constraint con
            ON con.conrelid OPERATOR(pg_catalog.=) chain.oid AND con.contype OPERATOR(pg_catalog.=) 'f'
        )
        SELECT n.nspname, c.relname
        FROM chain
        JOIN pg_catalog.pg_class c ON c.oid OPERATOR(pg_catalog.=) chain.oid
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        ORDER BY n.nspname COLLATE "C", c.relname COLLATE "C"
      SQL

      # public, if the database has it.
      ALWAYS_SQL = "SELECT nspname FROM pg_catalog.pg_namespace WHERE nspname OPERATOR(pg_catalog.=) 'public'"

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
      DEPENDS_SQL = <<~SQL
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
      RELATIONS_SQL = <<~SQL
        SELECT n.nspname, c.relname, c.relkind OPERATOR(pg_catalog.=) ANY ('{r,p}'::pg_catalog."char"[]),
               pg_catalog.has_schema_privilege(n.oid, 'USAGE') AND pg_catalog.has_table_privilege(c.oid, 'SELECT')
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) c.relnamespace
        WHERE c.relkind OPERATOR(pg_catalog.=) ANY (#{RELKINDS})
          AND n.nspname OPERATOR(pg_catalog.=) ANY (SELECT pg_catalog.json_array_elements_text($1::pg_catalog.json))
        ORDER BY n.nspname COLLATE "C", c.relname COLLATE "C"
      SQL

      # Every extension but plpgsql, which every database already has, and
      # its schema. pg_dump emits CREATE EXTENSION only for those named with
      # --extension when it also has --schema, and arena needs them.
      EXTENSIONS_SQL = "SELECT e.extname, n.nspname FROM pg_catalog.pg_extension e " \
                       "JOIN pg_catalog.pg_namespace n ON n.oid OPERATOR(pg_catalog.=) e.extnamespace " \
                       "WHERE e.extname OPERATOR(pg_catalog.<>) 'plpgsql'"

      FLAGS = %w[--schema-only --no-owner --no-privileges --strict-names --encoding=UTF8 --no-password].freeze

      # How long pg_dump waits for each table's lock before it gives up, so
      # a long ACCESS EXCLUSIVE lock on production fails the step instead of
      # hanging it.
      LOCK_WAIT_TIMEOUT = "30s"

      VERSION = /\Apg_dump \(PostgreSQL\) (\d+)/
      MISSING = "pg_dump couldn't be run, or didn't say its version"

      module_function

      def run(store:, relations:, connection:, conninfo:, pg_dump: ["pg_dump"], # rubocop:disable Metrics/ParameterLists
              lock_wait_timeout: LOCK_WAIT_TIMEOUT, extra_schemas: [])
        Checks.no_secrets!(conninfo)
        Checks.not_sql_ascii!(connection)
        tables = ancestors(relations, connection)
        new_enough!(pg_dump, connection)
        namespaces, full = full_dump(pg_dump, conninfo, tables, connection, lock_wait_timeout, extra_schemas)
        subset = subset_ddl(pg_dump, conninfo, tables, lock_wait_timeout:)
        store.write("schema_dump", { "namespaces" => namespaces, "ddl" => full })
        store.write("schema_subset", { "tables" => tables.map { [it.schema, it.name] }, "ddl" => subset })
        Result.new(namespaces:, tables:)
      end

      # The full dump's namespaces, with each extension's schema but a
      # system schema, and its DDL, with each extension. tables are the
      # query's tables and their FK ancestors, so an FK into a schema the
      # query doesn't touch still has its parent table in arena.
      #
      # extra_schemas, the operator's extra_dump_schemas, are dumped whole
      # like those. Then come the namespaces of whatever those depend on
      # (Depends), less the relations nothing needs, which --exclude-table
      # leaves out. Every table pg_dump will lock must be readable first.
      def full_dump(pg_dump, conninfo, tables, connection, lock_wait_timeout, extra_schemas = []) # rubocop:disable Metrics/ParameterLists
        extensions = extensions(connection)
        whole = (namespaces(tables, connection) + extensions.values + extra_schemas).uniq
        whole = whole.reject { system_schema?(it) }
        added, excluded = Depends.added(connection, whole)
        namespaces = (whole + added).sort
        Depends.readable!(connection, namespaces, excluded)
        selections = namespaces.map { "--schema=#{pattern(it)}" } +
                     excluded.map { "--exclude-table=#{pattern(*it)}" } +
                     extensions.keys.map { "--extension=#{pattern(it)}" }
        [namespaces, dump(pg_dump, conninfo, selections, lock_wait_timeout:)]
      end

      # The objects the dumped namespaces depend on (DESIGN.md's
      # schema-dump), by pg_depend. Postgres records what a column default,
      # a view, a constraint, or a SQL function with a BEGIN ATOMIC body
      # uses, but not what a function with a string body does, so the
      # operator names those schemas in extra_dump_schemas.
      module Depends
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

      # pg_catalog, information_schema, or any other pg_ schema, such as
      # pg_toast. A --schema for one has pg_dump dump the system catalog
      # itself: a read-only role can't lock pg_authid, so pg_dump fails, and
      # a superuser's dump holds DDL for the catalog's own objects, which
      # won't load into arena. --extension alone still brings an extension
      # that lives there, such as plperl.
      def system_schema?(name) = name == "information_schema" || name.start_with?("pg_")

      # Each extension's name, but plpgsql's, to its schema's.
      def extensions(connection)
        connection.exec_params(EXTENSIONS_SQL, []).values.to_h { |row| row.map { utf8(it) } }
      end

      # Refusals made before anything is dumped.
      module Checks
        module_function

        # A libpq keyword that holds a secret: password, sslpassword, and
        # oauth_client_secret today. passfile only names a file, so it's fine.
        SECRET_KEY = /(?:password|secret)\z/

        # A libpq keyword is lower case letters and underscores.
        PLAIN_KEY = /\A[a-z_]+\z/

        # libpq reads a dbname holding = or a postgres:// or postgresql:// URI
        # as a connection string. Its URI prefix match is case sensitive.
        CONNECTION_STRING = %r{=|\Apostgres(?:ql)?://}

        ENCODING_SQL = "SELECT pg_catalog.pg_encoding_to_char(encoding) FROM pg_catalog.pg_database " \
                       "WHERE datname OPERATOR(pg_catalog.=) pg_catalog.current_database()"

        def no_secrets!(conninfo)
          unless conninfo.keys.all? { PLAIN_KEY.match?(it.to_s) }
            raise Error.new("bad_conninfo_key", "a conninfo key must be a plain libpq keyword")
          end
          return unless conninfo.any? do |key, value|
            SECRET_KEY.match?(key.to_s) || (key.to_s == "dbname" && CONNECTION_STRING.match?(value.to_s))
          end

          raise Error.new("secret_in_conninfo", "pg_dump gets its secrets from the operator's own libpq setup")
        end

        def not_sql_ascii!(connection)
          encoding = connection.exec_params(ENCODING_SQL, []).getvalue(0, 0)
          raise Error.new("sql_ascii_database", "a SQL_ASCII database isn't supported") if encoding == "SQL_ASCII"
        end
      end

      # The tables' schemas, plus public if the database has it, since
      # --strict-names fails a dump on a schema that isn't there. Sorted by
      # byte, as the tables are.
      def namespaces(tables, connection)
        (tables.map(&:schema) + connection.exec_params(ALWAYS_SQL, []).column_values(0)).uniq.sort
      end

      # The relations and their FK ancestors, sorted.
      def ancestors(relations, connection)
        start = JSON.generate(relations.map { { schema: it.schema, name: it.name } })
        rows = connection.exec_params(ANCESTORS_SQL, [start]).values
        tables = rows.map { |schema, name| TableName.new(schema: utf8(schema), name: utf8(name)) }
        missing = relations.find { !tables.include?(it) }
        raise Error.new("unknown_relation", "#{missing} doesn't exist") if missing

        tables
      end

      # A name from the catalog comes back in the connection's client
      # encoding, the database's own unless the caller set another, such as
      # ISO-8859-1 for a LATIN1 database. The query's names are UTF-8, so
      # it's transcoded to match. The connection itself is left alone.
      def utf8(name) = name.encode(Encoding::UTF_8)

      def new_enough!(pg_dump, connection)
        ours = pg_dump_major(pg_dump)
        server = connection.exec_params("SELECT pg_catalog.current_setting('server_version_num')", []).getvalue(0, 0)
        theirs = Integer(server) / 10_000
        return if ours >= theirs

        raise Error.new("pg_dump_too_old", "pg_dump is major version #{ours}, older than the server's #{theirs}")
      end

      def pg_dump_major(pg_dump)
        out, = capture(pg_dump + ["--version"])
        version = out[VERSION, 1]
        return Integer(version) if version

        raise Error.new("pg_dump_missing", MISSING)
      rescue SystemCallError
        raise Error.new("pg_dump_missing", MISSING), cause: nil
      end

      # pg_dump with no --table dumps every table, so no tables is no DDL.
      def subset_ddl(pg_dump, conninfo, tables, lock_wait_timeout:)
        return "" if tables.empty?

        dump(pg_dump, conninfo, tables.map { "--table=#{pattern(it.schema, it.name)}" }, lock_wait_timeout:)
      end

      # pg_dump's output for selections, its --schema or --table arguments.
      # Its stderr is dropped unread.
      def dump(pg_dump, conninfo, selections, lock_wait_timeout: LOCK_WAIT_TIMEOUT)
        out, status = capture([*pg_dump, *FLAGS, "--lock-wait-timeout=#{lock_wait_timeout}", *selections,
                               "--dbname=#{conninfo_string(conninfo)}"])
        return out.force_encoding(Encoding::UTF_8) if status.success?

        raise Error.new("pg_dump_failed", "pg_dump exited with status #{status.exitstatus || "none (a signal)"}")
      end

      # Runs argv with no shell, even for one word: a [command, argv0]
      # pair is never handed to a shell. Returns stdout and the status.
      def capture(argv)
        out, _err, status = Open3.capture3([argv.first, argv.first], *argv.drop(1))
        [out, status]
      end

      # A name pg_dump matches exactly: quoted, so case, dots, and the
      # wildcards * and ? are taken as they are, with each " doubled.
      def pattern(*names) = names.map { "\"#{it.gsub('"', '""')}\"" }.join(".")

      # A libpq connection string: each value single-quoted, with ' and \
      # escaped by a backslash.
      def conninfo_string(conninfo)
        conninfo.map { |key, value| "#{key}='#{value.to_s.gsub(/[\\']/) { "\\#{it}" }}'" }.join(" ")
      end
    end
  end
end
