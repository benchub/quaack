# frozen_string_literal: true

require "tmpdir"
require "quaack/enclave/run_server"
require "quaack/enclave/store"

# The checks on `quaacks run-server`'s arguments (DESIGN.md's run-server). Each is
# refused rather than guessed at.
RSpec.describe Quaack::Enclave::RunServer do
  let(:good) { { host: "run-db-7.internal", port: "5433", racetrack_db: "racetrack", arena_db: "arena_1" } }

  def refusal(**args)
    described_class.record(**good, **args)
    nil
  rescue Quaack::Enclave::RunServer::Error => e
    e
  end

  def expect_refused(rule, **args)
    error = refusal(**args)
    expect(error).not_to be_nil, "#{args.inspect} was accepted"
    expect([error.rule, error.message]).to eq([rule, rule]), args.inspect
  end

  it "returns the run server entry, with the port as an Integer" do
    expect(described_class.record(**good))
      .to eq("host" => "run-db-7.internal", "port" => 5433, "racetrack_db" => "racetrack", "arena_db" => "arena_1")
  end

  it "takes an IPv4 address and the lowest and highest ports" do
    expect(described_class.record(**good, host: "10.0.4.12", port: "1")["port"]).to eq(1)
    expect(described_class.record(**good, port: "65535")["port"]).to eq(65_535)
  end

  it "refuses a host that isn't a plain hostname as bad_run_server_host" do
    ["", "-db", ".db", "db host", "db;x", "/tmp", "db\n", "dö", "a" * 254, "host=db", "db:5432"].each do |host|
      expect_refused("bad_run_server_host", host:)
    end
  end

  it "refuses a port that isn't a whole number from 1 to 65535 as bad_run_server_port" do
    ["", "0", "65536", "-1", "+5432", " 5432", "5432\n", "54a", "5432.0", "0x10", "05432", "99999999", "５４３２",
     "\xff", "54\xff32", "5432".encode("UTF-16LE")].each do |port|
      expect_refused("bad_run_server_port", port:)
    end
  end

  it "refuses a database name that isn't a plain identifier of up to 63 characters as bad_run_server_database" do
    ["", "a b", "a;b", "a\"b", "a'b", "dbname=x", "ä", "a" * 64, "a\n", "-a", "a.b"].each do |name|
      expect_refused("bad_run_server_database", racetrack_db: name)
      expect_refused("bad_run_server_database", arena_db: name)
    end
  end

  it "takes a database name of exactly 63 characters" do
    expect(described_class.record(**good, arena_db: "a" * 63)["arena_db"]).to eq("a" * 63)
  end

  # arena-setup builds arena from scratch, so sharing a name would put it on top of
  # the racetrack.
  it "refuses the same database for the racetrack and arena as run_server_same_database" do
    expect_refused("run_server_same_database", arena_db: "racetrack")
  end

  # An arena session takes production's TimeZone from inventory, so an
  # inventory without one isn't one this version wrote (task 20261006-6).
  describe ".connect" do
    def connect_error(settings)
      Dir.mktmpdir do |base|
        store = Quaack::Enclave::Store.create(base:)
        store.write("run_server", "host" => "127.0.0.1", "port" => 1, "racetrack_db" => "r", "arena_db" => "a")
        store.write("inventory", "settings" => settings)
        described_class.connect(store, :arena)
      rescue described_class::Error => e
        e
      end
    end

    it "refuses an arena connection as run_from_older_version when the inventory has no TimeZone" do
      error = connect_error("work_mem" => "4MB")

      expect([error.class, error.rule]).to eq([described_class::Error, "run_from_older_version"])
    end

    it "refuses a TimeZone that isn't a non-empty string the same way, and never reads it as a connection error" do
      expect(connect_error("TimeZone" => nil).rule).to eq("run_from_older_version")
      expect(connect_error("TimeZone" => "").rule).to eq("run_from_older_version")
    end
  end
end
