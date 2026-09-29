# frozen_string_literal: true

require "quaack/enclave/run_server"

# The checks on `quaacks run-server`'s arguments (DESIGN.md, step 4). Each is
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
    ["", "0", "65536", "-1", "+5432", " 5432", "5432\n", "54a", "5432.0", "0x10", "05432", "99999999"].each do |port|
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

  # 4b builds arena from scratch, so sharing a name would put it on top of
  # the racetrack.
  it "refuses the same database for the racetrack and arena as run_server_same_database" do
    expect_refused("run_server_same_database", arena_db: "racetrack")
  end
end
