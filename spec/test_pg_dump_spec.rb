# frozen_string_literal: true

require_relative "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"

# Task 20260929-9: the harness finds a pg_dump of the test server's major
# version for the quaacks children it starts, so a Mac whose PATH has an
# older pg_dump still runs the replay.
RSpec.describe TestPgDump do
  # A stand-in pg_dump in dir that prints version for --version.
  def fake_pg_dump(dir, version)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "pg_dump")
    File.write(path, "#!/bin/sh\necho '#{version}'\n")
    File.chmod(0o755, path)
    dir
  end

  around { |example| Dir.mktmpdir("quaack-pg-dump") { |tmp| @tmp = tmp and example.run } }

  let(:given) { File.join(@tmp, "given") }
  let(:keg) { File.join(@tmp, "keg") }

  def candidates(env) = described_class.candidates(env, homebrew: keg)

  describe ".candidates" do
    it "checks QUAACK_TEST_PG_BIN first, then Homebrew's libpq keg" do
      expect(candidates("QUAACK_TEST_PG_BIN" => given)).to eq([given, keg])
    end

    it "checks only the keg when QUAACK_TEST_PG_BIN is unset or empty" do
      expect(candidates({})).to eq([keg])
      expect(candidates("QUAACK_TEST_PG_BIN" => "")).to eq([keg])
    end

    it "uses Homebrew's libpq keg by default" do
      expect(described_class.candidates({})).to eq(["/opt/homebrew/opt/libpq/bin"])
    end
  end

  describe ".find" do
    it "picks QUAACK_TEST_PG_BIN's directory when its pg_dump has the server's major version" do
      fake_pg_dump(given, "pg_dump (PostgreSQL) 18.2")
      fake_pg_dump(keg, "pg_dump (PostgreSQL) 18.6")
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given))).to eq(given)
    end

    it "falls back to Homebrew's libpq keg" do
      fake_pg_dump(keg, "pg_dump (PostgreSQL) 18.6")
      expect(described_class.find(18, candidates({}))).to eq(keg)
    end

    it "skips a pg_dump of another major version, older or newer" do
      fake_pg_dump(given, "pg_dump (PostgreSQL) 14.19 (Homebrew)")
      fake_pg_dump(keg, "pg_dump (PostgreSQL) 18.6")
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given))).to eq(keg)

      fake_pg_dump(given, "pg_dump (PostgreSQL) 19.0")
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given))).to eq(keg)
    end

    it "skips a directory with no pg_dump in it" do
      FileUtils.mkdir_p(given)
      fake_pg_dump(keg, "pg_dump (PostgreSQL) 18.6")
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given))).to eq(keg)
    end

    it "skips a program that doesn't say its version the way pg_dump does" do
      fake_pg_dump(given, "not pg_dump (PostgreSQL) 18.6")
      expect { described_class.find(18, [given]) }.to raise_error(TestPgDump::NotFound)
    end

    it "says what to install or set when none has the server's major version" do
      fake_pg_dump(given, "pg_dump (PostgreSQL) 17.6")
      expect { described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given)) }
        .to raise_error(TestPgDump::NotFound, <<~MSG.chomp)
          The specs that run quaacks need pg_dump 18, the test server's major version, and found none. Looked in:
            #{given}: pg_dump (PostgreSQL) 17.6
            #{keg}: no pg_dump
          Install Homebrew's libpq at major version 18 (brew install libpq), or set QUAACK_TEST_PG_BIN to a directory that holds pg_dump 18.
        MSG
    end
  end

  def running_major = test_database.connection.exec("SHOW server_version_num").getvalue(0, 0).to_i / 10_000

  describe ".bin" do
    it "is the directory of a pg_dump whose major version is the running test server's" do
      out, status = Open3.capture2(File.join(described_class.bin, "pg_dump"), "--version")
      expect(status).to be_success
      expect(out[/\Apg_dump \(PostgreSQL\) (\d+)/, 1].to_i).to eq(running_major)
    end
  end

  # Read from the image, so the replay spec can check for pg_dump when it
  # loads, before any container starts.
  it "takes the test server's major version from its image" do
    expect(described_class.server_major).to eq(running_major)
  end
end

# The replay's quaacks children get that pg_dump first on their PATH, even
# when the PATH they'd otherwise inherit starts with an older one.
RSpec.describe "PromptPack.with_env" do
  let(:server) { TestPostgres.server }
  let(:query) { PromptPack::QUERIES.first }

  # Runs intake and the setup steps through schema-dump in quaacks children,
  # and returns the schema dump the run stored.
  def schema_dump(home, prod, racetrack)
    transport = Quaack::Driver::Transport::Local.new(command: PromptPack::QUAACKS)
    run_id = PromptPack.intake(transport, home, server, query, prod)
    transport.call("inventory", args: { run: run_id })
    transport.call("run-server", args: { :run => run_id, "host" => server.host, "port" => server.port.to_s,
                                         "racetrack-db" => racetrack, "arena-db" => "#{racetrack}_arena" })
    transport.call("qualify", args: { run: run_id })
    transport.call("schema-dump", args: { run: run_id })
    JSON.parse(File.read(File.join(home, ".quaack", "runs", run_id, "schema_dump.json")))
  end

  it "gives a quaacks child a pg_dump of the server's major version, so its schema-dump succeeds" do
    Dir.mktmpdir("quaack-old-pg-dump") do |old|
      File.write(File.join(old, "pg_dump"), "#!/bin/sh\necho 'pg_dump (PostgreSQL) 14.19 (Homebrew)'\n")
      File.chmod(0o755, File.join(old, "pg_dump"))
      saved = ENV.fetch("PATH")
      ENV["PATH"] = "#{old}:#{saved}"
      Dir.mktmpdir("quaack-home") do |home|
        server.admin.exec("SET client_min_messages = warning")
        prod, racetrack = PromptPack.databases(server, query)
        dump = PromptPack.with_env(home, server, prod) { schema_dump(home, prod, racetrack) }
        expect(dump["ddl"]).to match(/^-- Dumped by pg_dump version #{server.admin.server_version / 10_000}\./)
        expect(dump["ddl"]).to include("CREATE TABLE public.orders (")
        # The spec's own PATH, with the old pg_dump first, is back as it was.
        expect(ENV.fetch("PATH")).to eq("#{old}:#{saved}")
      ensure
        PipelineReplay.drop(server, [prod, racetrack, "#{racetrack}_arena"].compact)
      end
    ensure
      ENV["PATH"] = saved if saved
    end
  end
end
