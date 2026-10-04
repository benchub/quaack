# frozen_string_literal: true

require "pg"
require_relative "racetrack"

module Quaack
  module Enclave
    # DESIGN.md's arena-setup: build arena, the empty database rewrite-test loads fixtures into.
    #
    #   Arena.build(store:, racetrack:, name:, connect:)  # nil, or raises an Error
    #
    # racetrack is a superuser's connection to the run server's racetrack
    # database, used only to create and drop arena; name is the run's
    # arena_db; connect is called with no arguments once arena exists and
    # returns a connection to it.
    #
    # Arena is made from template0 with inventory's locale settings (the
    # inventory's database entry): its provider (c libc, i ICU, b builtin),
    # LC_COLLATE, LC_CTYPE, and its ICU or builtin locale. The inventory
    # doesn't record the encoding, so arena gets the run server's default.
    # It's tagged with COMMENT, and a rerun drops and rebuilds a tagged
    # database. An untagged database of that name is arena_database_foreign
    # and is left alone.
    #
    # Into it goes schema-dump's full dump, with pg_dump's \restrict and \unrestrict
    # lines removed, as one implicit transaction. The fresh database's
    # public schema is dropped first, since the dump runs CREATE SCHEMA
    # public. A dump that won't load is arena_dump_load_failed. Then the
    # quaack schema and clock_anchor(), as on the racetrack (hypopg isn't
    # needed), and DISABLE TRIGGER USER on every table with a user trigger,
    # so FK triggers still fire. Constraints are left as the dump made them.
    #
    # An Error's message is its rule and nothing else.
    module Arena
      class Error < StandardError
        attr_reader :rule

        def initialize(rule)
          @rule = rule
          super
        end
      end

      TAG = "quaack arena"
      PROVIDERS = { "c" => ["libc", nil], "i" => %w[icu ICU_LOCALE], "b" => %w[builtin BUILTIN_LOCALE] }.freeze
      RESTRICT = /^\\(un)?restrict .*\n?/

      USER_TRIGGER_TABLES_SQL = <<~SQL
        SELECT DISTINCT n.nspname, c.relname FROM pg_catalog.pg_trigger t
        JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT t.tgisinternal AND t.tgparentid = 0
      SQL

      module_function

      def build(store:, racetrack:, name:, connect:)
        literal = Racetrack.anchor_literal(store.read("clock_anchor"))
        recreate(racetrack, name, store.read("inventory").fetch("database"))
        arena = connect.call
        load_dump(arena, store.read("schema_dump").fetch("ddl"))
        Racetrack.create_clock_anchor(arena, literal)
        disable_user_triggers(arena)
        nil
      ensure
        arena&.close
      end

      def recreate(conn, name, database)
        ident = conn.quote_ident(name)
        comment = conn.exec_params("SELECT pg_catalog.shobj_description(oid, 'pg_database') FROM " \
                                   "pg_catalog.pg_database WHERE datname = $1", [name]).values
        unless comment.empty?
          raise Error, "arena_database_foreign" unless comment == [[TAG]]

          conn.exec("DROP DATABASE #{ident} WITH (FORCE)")
        end
        conn.exec("CREATE DATABASE #{ident} TEMPLATE template0 #{locale(conn, database)}")
        conn.exec("COMMENT ON DATABASE #{ident} IS #{conn.escape_literal(TAG)}")
      end

      def locale(conn, database)
        provider, keyword = PROVIDERS.fetch(database.fetch("datlocprovider"))
        parts = ["LOCALE_PROVIDER #{provider}", "LC_COLLATE #{conn.escape_literal(database.fetch("datcollate"))}",
                 "LC_CTYPE #{conn.escape_literal(database.fetch("datctype"))}"]
        parts << "#{keyword} #{conn.escape_literal(database.fetch("datlocale"))}" if keyword
        parts.join(" ")
      end

      def load_dump(conn, ddl)
        conn.exec("DROP SCHEMA public")
        conn.exec(ddl.gsub(RESTRICT, ""))
        conn.exec("RESET ALL")
      rescue PG::Error
        raise Error, "arena_dump_load_failed", cause: nil
      end

      def disable_user_triggers(conn)
        conn.exec(USER_TRIGGER_TABLES_SQL).each_row do |schema, table|
          conn.exec("ALTER TABLE #{conn.quote_ident(schema)}.#{conn.quote_ident(table)} DISABLE TRIGGER USER")
        end
      end
    end
  end
end
