# frozen_string_literal: true

require "open3"
require_relative "test_postgres"

# The pg_dump for the quaacks children the specs and scripts start (task
# 20260929-9). quaacks schema-dump runs pg_dump from PATH, and pg_dump
# refuses a server of a later major version, so a development Mac whose
# PATH has an older pg_dump can't dump the test server. The harness looks
# for a pg_dump whose major version is the test server's, first in the
# directory QUAACK_TEST_PG_BIN names, if it's set, then in Homebrew's libpq
# keg, and puts that directory first on PATH only for its quaacks children
# (PromptPack.with_env and E2ERun.with_env). The shell's own PATH is left
# alone.
module TestPgDump
  class NotFound < StandardError; end

  ENV_VAR = "QUAACK_TEST_PG_BIN"
  HOMEBREW_LIBPQ = "/opt/homebrew/opt/libpq/bin"
  VERSION = /\Apg_dump \(PostgreSQL\) (\d+)/

  module_function

  # The test server's major version, such as 18, from its image's FROM line
  # (TestPostgres), so it's known without starting a container.
  def server_major(dir = TestPostgres::DIR)
    Integer(File.read(File.join(dir, "Dockerfile"))[/^FROM postgres:(\d+)\b/, 1])
  end

  # The directories to look in, in order.
  def candidates(env = ENV, homebrew: HOMEBREW_LIBPQ)
    [env[ENV_VAR], homebrew].reject { it.nil? || it.empty? }
  end

  # The first of dirs whose pg_dump has major version major. Raises NotFound,
  # saying what each held and what to install or set, when none does.
  def find(major, dirs)
    found = dirs.to_h { [it, version(File.join(it, "pg_dump"))] }
    dirs.find { found[it]&.match(VERSION)&.[](1).to_i == major } or raise NotFound, not_found(major, found)
  end

  # What pg_dump --version printed, or nil if it couldn't be run.
  def version(path)
    return nil unless File.executable?(path)

    out, status = Open3.capture2(path, "--version")
    status.success? ? out.strip : nil
  rescue SystemCallError
    nil
  end

  def not_found(major, found)
    looked = found.map { |dir, version| "  #{dir}: #{version || "no pg_dump"}" }
    ["The specs that run quaacks need pg_dump #{major}, the test server's major version, and found none. Looked in:",
     *looked,
     "Install Homebrew's libpq at major version #{major} (brew install libpq), " \
     "or set #{ENV_VAR} to a directory that holds pg_dump #{major}."].join("\n")
  end

  # The directory for the test server's major version, found once per
  # process.
  def bin = @bin ||= find(server_major, candidates)
end
