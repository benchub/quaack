# frozen_string_literal: true

require_relative "spec_helper"
require "fileutils"
require "open3"
require "stringio"
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
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given), warn_to: StringIO.new)).to eq(keg)

      fake_pg_dump(given, "pg_dump (PostgreSQL) 19.0")
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given), warn_to: StringIO.new)).to eq(keg)
    end

    it "skips a directory with no pg_dump in it" do
      FileUtils.mkdir_p(given)
      fake_pg_dump(keg, "pg_dump (PostgreSQL) 18.6")
      warnings = StringIO.new
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given), warn_to: warnings)).to eq(keg)
      expect(warnings.string).to be_empty
    end

    it "skips a program that doesn't say its version the way pg_dump does" do
      fake_pg_dump(given, "not pg_dump (PostgreSQL) 18.6")
      expect { described_class.find(18, [given]) }.to raise_error(TestPgDump::NotFound)
    end

    it "skips a pg_dump that prints the right version but exits non-zero" do
      FileUtils.mkdir_p(given)
      File.write(File.join(given, "pg_dump"), "#!/bin/sh\necho 'pg_dump (PostgreSQL) 18.6'\nexit 1\n")
      File.chmod(0o755, File.join(given, "pg_dump"))
      fake_pg_dump(keg, "pg_dump (PostgreSQL) 18.2")
      expect(described_class.version(File.join(given, "pg_dump"))).to be_nil
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given), warn_to: StringIO.new)).to eq(keg)
    end

    it "says so when it skips QUAACK_TEST_PG_BIN's pg_dump for the keg" do
      fake_pg_dump(given, "pg_dump (PostgreSQL) 17.6")
      fake_pg_dump(keg, "pg_dump (PostgreSQL) 18.2")
      warnings = StringIO.new
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given), warn_to: warnings)).to eq(keg)
      expect(warnings.string).to eq("Skipped #{given}, which holds pg_dump (PostgreSQL) 17.6, not pg_dump 18. " \
                                    "Using #{keg}.\n")
    end

    it "says nothing when the first directory it checks has the server's major version" do
      fake_pg_dump(given, "pg_dump (PostgreSQL) 18.2")
      warnings = StringIO.new
      expect(described_class.find(18, candidates("QUAACK_TEST_PG_BIN" => given), warn_to: warnings)).to eq(given)
      expect(warnings.string).to eq("")
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

  # Numbers come before the FROM line, even one in a comment that quotes an
  # old FROM line, so only the real FROM line gives 17.
  it "reads the major version from the image's FROM line" do
    dockerfile = <<~DOCKERFILE
      # This image was FROM postgres:16 before the upgrade.
      ARG PG_MAJOR=16
      FROM postgres:17

      RUN true
    DOCKERFILE
    File.write(File.join(@tmp, "Dockerfile"), dockerfile)
    expect(described_class.server_major(@tmp)).to eq(17)
  end
end

# The load-time gate the replay and scenario-refusal specs use: with a
# pg_dump, the group gets its examples; without one, it gets a single
# example that fails with what to install or set.
RSpec.describe "TestPgDump.examples" do
  # Stands in for an example group: records what the gate gives it.
  let(:group) do
    Class.new do
      def self.examples = (@examples ||= [])
      def self.it(description, &block) = examples << [description, block]
    end
  end

  it "defines the group's own examples when a pg_dump is found" do
    TestPgDump.examples(group, "needs pg_dump", find: -> { "/some/bin" }) { it("a run") { :ran } }
    expect(group.examples.map(&:first)).to eq(["a run"])
  end

  it "defines one failing example, and none of the group's own, when no pg_dump is found" do
    find = -> { raise TestPgDump::NotFound, "install pg_dump 18" }
    TestPgDump.examples(group, "needs pg_dump", find:) { raise "must not run" }
    expect(group.examples.map(&:first)).to eq(["needs pg_dump"])
    expect { group.examples.first.last.call }.to raise_error(TestPgDump::NotFound, "install pg_dump 18")
  end
end

# The scripts' with_env puts the found pg_dump's directory first on PATH
# for the block, and puts PATH back after.
[["PromptPack", -> { PromptPack }], ["E2ERun", -> { E2ERun }]].each do |name, mod|
  RSpec.describe "#{name}.with_env" do
    it "starts with the found pg_dump's directory inside the block, and is restored after" do
      # The finder is faked here: what's under test is with_env.
      allow(TestPgDump).to receive(:bin).and_return("/found/pg/bin")
      server = Data.define(:host, :port).new(host: "127.0.0.1", port: 5432)
      before = ENV.fetch("PATH")
      inside = mod.call.with_env("/nonexistent/home", server, "prod") { ENV.fetch("PATH") }
      expect(inside).to eq("/found/pg/bin:#{before}")
      expect(ENV.fetch("PATH")).to eq(before)
    end

    # With no pg_dump found, with_env says so, and leaves the environment
    # as it was.
    it "raises the finder's NotFound, not another error, and leaves ENV unchanged, when there's no pg_dump" do
      # The finder is faked here: what's under test is with_env.
      allow(TestPgDump).to receive(:bin).and_raise(TestPgDump::NotFound, "no pg_dump 18")
      server = Data.define(:host, :port).new(host: "127.0.0.1", port: 5432)
      before = ENV.to_h
      expect { mod.call.with_env("/nonexistent/home", server, "prod") { raise "must not run" } }
        .to raise_error(TestPgDump::NotFound, "no pg_dump 18")
      expect(ENV.to_h).to eq(before)
    end
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
