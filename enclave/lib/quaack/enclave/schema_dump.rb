# frozen_string_literal: true

require "json"
require "open3"
require_relative "table_name"

module Quaack
  module Enclave
    # README 3b: the schema-only dump of every namespace the query touches,
    # plus public, and the subset: the query's tables and their whole FK
    # ancestor chain. Both go into the governed store, and nothing here
    # leaves the enclave.
    #
    #   SchemaDump.run(store:, relations: Relations.check(sql, settings, conn).relations,
    #                  connection: conn, conninfo: { host: "db1", dbname: "app" })
    #   # => Result(namespaces: ["public", "sales"], tables: [TableName(public.customers), ...])
    #   store.read("schema_dump")   # => { "namespaces" => [...], "ddl" => "<pg_dump output>" }
    #   store.read("schema_subset") # => { "tables" => [["public", "customers"], ...], "ddl" => "..." }
    #
    # The inputs:
    # - relations: the qualified TableNames from Relations.check, the
    #   query's tables. Their schemas, plus public if the database has it,
    #   are the namespaces.
    # - connection: a PG connection to the production database, for the
    #   catalog and the server's version. Only plain SELECTs are run on it,
    #   and its settings, including its client encoding, are left alone.
    # - conninfo: libpq connection parameters for pg_dump, such as host,
    #   port, dbname, user, or service, as a Hash. pg_dump runs with the
    #   operator's own libpq setup on the jump server (PGUSER, ~/.pgpass,
    #   ~/.pg_service.conf), and QUAACK stores no credentials, so a secret
    #   (password, sslpassword, oauth_client_secret) is refused: pg_dump's
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
    # print its version), pg_dump_too_old, and pg_dump_failed. pg_dump's
    # stderr carries server messages, which can quote values, and names
    # what it was asked for, so it's never read: pg_dump_failed says only
    # the exit status. So a lock wait that timed out is pg_dump_failed too,
    # since pg_dump exits 1 for that as for any other failure. A refusal
    # stores nothing.
    module SchemaDump
      class Error < StandardError
        attr_reader :rule

        def initialize(rule, detail)
          @rule = rule
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
          FROM json_to_recordset($1::json) AS start (schema text, name text)
          JOIN pg_catalog.pg_namespace n ON n.nspname = start.schema
          JOIN pg_catalog.pg_class c ON c.relnamespace = n.oid AND c.relname = start.name
          UNION
          SELECT con.confrelid
          FROM chain
          JOIN pg_catalog.pg_constraint con ON con.conrelid = chain.oid AND con.contype = 'f'
        )
        SELECT n.nspname, c.relname
        FROM chain
        JOIN pg_catalog.pg_class c ON c.oid = chain.oid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        ORDER BY n.nspname COLLATE "C", c.relname COLLATE "C"
      SQL

      PUBLIC_SQL = "SELECT EXISTS (SELECT FROM pg_catalog.pg_namespace WHERE nspname = 'public')"

      FLAGS = %w[--schema-only --no-owner --no-privileges --strict-names --encoding=UTF8].freeze

      # How long pg_dump waits for each table's lock before it gives up, so
      # a long ACCESS EXCLUSIVE lock on production fails the step instead of
      # hanging it.
      LOCK_WAIT_TIMEOUT = "30s"

      VERSION = /\Apg_dump \(PostgreSQL\) (\d+)/
      MISSING = "pg_dump couldn't be run, or didn't say its version"

      module_function

      def run(store:, relations:, connection:, conninfo:, pg_dump: ["pg_dump"], # rubocop:disable Metrics/ParameterLists
              lock_wait_timeout: LOCK_WAIT_TIMEOUT)
        no_secrets!(conninfo)
        tables = ancestors(relations, connection)
        namespaces = namespaces(relations, connection)
        new_enough!(pg_dump, connection)
        full = dump(pg_dump, conninfo, namespaces.map { "--schema=#{pattern(it)}" }, lock_wait_timeout:)
        subset = subset_ddl(pg_dump, conninfo, tables, lock_wait_timeout:)
        store.write("schema_dump", { "namespaces" => namespaces, "ddl" => full })
        store.write("schema_subset", { "tables" => tables.map { [it.schema, it.name] }, "ddl" => subset })
        Result.new(namespaces:, tables:)
      end

      # A libpq keyword that holds a secret: password, sslpassword, and
      # oauth_client_secret today. passfile only names a file, so it's fine.
      SECRET_KEY = /(?:password|secret)\z/

      def no_secrets!(conninfo)
        return unless conninfo.any? { |key, _| SECRET_KEY.match?(key.to_s) }

        raise Error.new("secret_in_conninfo", "pg_dump gets its secrets from the operator's own libpq setup")
      end

      # The relations' schemas, plus public if the database has one, since
      # --strict-names fails a dump on a schema that isn't there. Sorted by
      # byte, as the tables are.
      def namespaces(relations, connection)
        public = connection.exec_params(PUBLIC_SQL, []).getvalue(0, 0) == "t"
        (relations.map(&:schema) + (public ? ["public"] : [])).uniq.sort
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
        server = connection.exec_params("SELECT current_setting('server_version_num')", []).getvalue(0, 0)
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
