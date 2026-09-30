# frozen_string_literal: true

# Objects in the public schema named like the catalog relations, functions,
# and types that step 2 (Inventory::Production) and step 4 (RunServerCheck)
# read. On a database whose search_path puts public before pg_catalog, an
# unqualified name finds these instead, and each one gives a wrong answer:
# a missing extension, a bogus setting, no clients, and so on.
#
#   CatalogShadow.plant(conn)                        # every one
#   CatalogShadow.plant(conn, :pg_stat_activity)     # just these
#
# Every name in the DDL is qualified, so it means the same whatever conn's
# search_path is. The text domain goes last, since it shadows text.
module CatalogShadow
  SHADOWS = {
    pg_stat_activity: [<<~SQL],
      CREATE TABLE public.pg_stat_activity
        (pid pg_catalog.int4, backend_start pg_catalog.timestamptz, backend_type pg_catalog.text)
    SQL
    pg_settings: [<<~SQL, <<~SQL],
      CREATE TABLE public.pg_settings
        (name pg_catalog.text, setting pg_catalog.text, boot_val pg_catalog.text, category pg_catalog.text)
    SQL
      INSERT INTO public.pg_settings VALUES ('quaack.shadow_parallel', 'x', 'y', 'Query Tuning / Shadow')
    SQL
    pg_extension: ["CREATE TABLE public.pg_extension (extname pg_catalog.name, extversion pg_catalog.text)"],
    pg_available_extensions: ["CREATE TABLE public.pg_available_extensions (name pg_catalog.name)"],
    pg_database: [<<~SQL, <<~SQL],
      CREATE TABLE public.pg_database
        (datname pg_catalog.name, datcollate pg_catalog.text, datctype pg_catalog.text,
         datlocprovider pg_catalog.char, datlocale pg_catalog.text, datcollversion pg_catalog.text)
    SQL
      INSERT INTO public.pg_database
      VALUES (pg_catalog.current_database(), 'shadow', 'shadow', 'c', 'shadow', 'shadow')
    SQL
    current_setting: [
      "CREATE FUNCTION public.current_setting(pg_catalog.text) RETURNS pg_catalog.text " \
      "LANGUAGE sql AS $$ SELECT 'shadow'::pg_catalog.text $$",
      "CREATE FUNCTION public.current_setting(pg_catalog.text, pg_catalog.bool) RETURNS pg_catalog.text " \
      "LANGUAGE sql AS $$ SELECT 'shadow'::pg_catalog.text $$"
    ],
    pg_backend_pid: ["CREATE FUNCTION public.pg_backend_pid() RETURNS pg_catalog.int4 LANGUAGE sql AS $$ SELECT 0 $$"],
    pg_settings_get_flags: [
      "CREATE FUNCTION public.pg_settings_get_flags(pg_catalog.text) RETURNS pg_catalog.text[] " \
      "LANGUAGE sql AS $$ SELECT '{}'::pg_catalog.text[] $$"
    ],
    json_array_elements_text: [
      "CREATE FUNCTION public.json_array_elements_text(pg_catalog.json) RETURNS SETOF pg_catalog.text " \
      "LANGUAGE sql AS $$ SELECT 'shadow'::pg_catalog.text WHERE false $$"
    ],
    to_char: [
      "CREATE FUNCTION public.to_char(pg_catalog.timestamp, pg_catalog.text) RETURNS pg_catalog.text " \
      "LANGUAGE sql AS $$ SELECT 'shadow'::pg_catalog.text $$"
    ],
    current_database: [
      "CREATE FUNCTION public.current_database() RETURNS pg_catalog.name " \
      "LANGUAGE sql AS $$ SELECT 'shadow'::pg_catalog.name $$"
    ],
    to_regclass: [
      "CREATE FUNCTION public.to_regclass(pg_catalog.text) RETURNS pg_catalog.regclass " \
      "LANGUAGE sql AS $$ SELECT 'pg_catalog.pg_class'::pg_catalog.regclass $$"
    ],
    count: [
      "CREATE AGGREGATE public.count(*) (sfunc = pg_catalog.int8inc, stype = pg_catalog.int8, initcond = '1000')"
    ],
    # json and int, unlike text, are keywords the parser reads as
    # pg_catalog's types, so they can't be shadowed.
    text: ["CREATE DOMAIN public.text AS pg_catalog.text CHECK (false)"]
  }.freeze

  module_function

  def plant(conn, *names)
    names = SHADOWS.keys if names.empty?
    SHADOWS.slice(*names).each_value { |statements| statements.each { conn.exec(it) } }
  end
end
