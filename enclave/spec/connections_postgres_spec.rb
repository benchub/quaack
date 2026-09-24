# frozen_string_literal: true

require "json"
require "quaack/enclave/connections"

# Stands in for a production value a RAISE NOTICE could print.
CONNECTIONS_SENTINEL = "SENTINEL-c41d7e-accounts.ssn"

# Checks the connection helper against real Postgres. A child process
# connects and calls a function that raises a notice and a warning holding
# the sentinel, so libpq's default notice handling, which writes to the
# process's stderr, can be seen.
RSpec.describe Quaack::Enclave::Connections do
  let(:conn) { test_database.connection }

  before do
    conn.exec(<<~SQL)
      CREATE FUNCTION connections_notice() RETURNS int LANGUAGE plpgsql STABLE AS $$
      BEGIN
        RAISE NOTICE 'notice %', #{conn.escape_literal(CONNECTIONS_SENTINEL)};
        RAISE WARNING 'warning %', #{conn.escape_literal(CONNECTIONS_SENTINEL)};
        RETURN 1;
      END $$
    SQL
  end

  def child(setup)
    run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", <<~RUBY, JSON.generate(test_database.connection_params))
      require "json"
      require "pg"
      require "quaack/enclave/connections"
      conn = PG.connect(**JSON.parse(ARGV[0], symbolize_names: true))
      #{setup}
      print conn.exec("SELECT connections_notice()").getvalue(0, 0)
      conn.close
    RUBY
  end

  it "shows the notices on stderr for a connection it isn't given, so the check works" do
    _out, err, status = child("")

    expect(status).to be_success
    expect(err).to include("notice #{CONNECTIONS_SENTINEL}").and include("warning #{CONNECTIONS_SENTINEL}")
  end

  it "drops every notice on a connection it registers" do
    out, err, status = child("Quaack::Enclave::Connections.register(conn)")

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq("1")
    expect(err).to eq("")
  end

  it "resets a connection and drops its notices again, since a reset forgets them" do
    out, err, status = child("Quaack::Enclave::Connections.register(conn); Quaack::Enclave::Connections.reset(conn)")

    expect(status).to be_success, "stderr was #{err}"
    expect(out).to eq("1")
    expect(err).to eq("")
  end

  it "really resets the connection" do
    own = described_class.register(test_database.connect)
    pid = own.backend_pid

    expect(described_class.reset(own)).to be(own)
    expect(own.backend_pid).not_to eq(pid)
  ensure
    own&.close
  end

  it "returns the connection it registers" do
    expect(described_class.register(conn)).to be(conn)
  end
end
