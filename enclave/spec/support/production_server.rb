# frozen_string_literal: true

require "pg"
require "securerandom"

# A stand-in for the production server inventory reads (DESIGN.md's inventory): a
# database of its own on the test harness's Postgres, made from template0
# with the builtin locale provider, so its pg_database locale fields differ
# from the harness's own databases. Its name, its text search config, and
# its search_path hold sentinels, standing in for production configuration
# that must stay in the enclave.
#
#   production = ProductionServer.create(sentinels)
#   production.drop                          # in an after hook
#
# sentinels must have been made with ProductionServer.sentinels, which adds
# the text search config's name.
class ProductionServer
  # Database-level settings, as production might have them.
  WORK_MEM = "7MB"

  def self.sentinels = LeakCheck::Sentinels.new(extra: { tsconfig: "sentinelts#{SecureRandom.hex(6)}" })

  def self.create(sentinels) = new(sentinels).tap(&:create)

  attr_reader :sentinels

  def initialize(sentinels)
    @sentinels = sentinels
  end

  def server = TestPostgres.server
  def name = sentinels.word
  def ts_config = sentinels.needles.fetch(:tsconfig)
  def host = server.host
  def port = server.port
  def user = TestPostgres::USER
  def password = TestPostgres::PASSWORD

  # search_path as current_setting prints it.
  def search_path = %("#{sentinels.text}", public)

  # port: can be another way in to the same server, such as PgBouncer's.
  def connect(port: self.port) = PG.connect(host:, port:, dbname: name, user:, password:)

  def create
    server.admin.exec(%(CREATE DATABASE "#{name}" TEMPLATE template0 LOCALE_PROVIDER builtin \
                        BUILTIN_LOCALE 'C.UTF-8' LOCALE 'C' ENCODING 'UTF8'))
    conn = connect
    conn.exec("CREATE EXTENSION hypopg")
    conn.exec("CREATE TEXT SEARCH CONFIGURATION public.#{ts_config} (COPY = pg_catalog.english)")
    # From inside the database, where the text search config exists, so
    # Postgres doesn't print a NOTICE that it doesn't.
    database_settings.each { conn.exec(%(ALTER DATABASE "#{name}" SET #{it})) }
  ensure
    conn&.close
  end

  def database_settings
    [%(default_text_search_config = 'public.#{ts_config}'), "search_path = #{search_path}", "work_mem = '#{WORK_MEM}'"]
  end

  def drop = server.admin.exec(%(DROP DATABASE IF EXISTS "#{name}" WITH (FORCE)))
end
