# frozen_string_literal: true

require "json"
require "stringio"
require "quaack/enclave/error_filter"

# Stands in for a real production value in a Postgres row or notice. It must
# never show up in anything the error filter writes or returns.
PG_ERROR_SENTINEL = "SENTINEL-9b02f7-accounts.ssn"

# Checks the error filter against errors and notices from real Postgres.
RSpec.describe "error filtering against real Postgres" do
  let(:filter) { Quaack::Enclave::ErrorFilter }
  let(:conn) { test_database.connection }

  def pg_error(sql)
    conn.exec(sql)
    raise "expected #{sql} to fail"
  rescue PG::Error => e
    e
  end

  def line(**fields) = JSON.generate({ "type" => "error", **fields.transform_keys(&:to_s) })

  before do
    bad = conn.escape_literal("#{PG_ERROR_SENTINEL}-bad")
    conn.exec("CREATE TABLE filter_accounts (ssn text UNIQUE CHECK (ssn <> #{bad}))")
    conn.exec_params("INSERT INTO filter_accounts VALUES ($1)", [PG_ERROR_SENTINEL])
  end

  it "filters a unique violation, whose DETAIL holds the key" do
    error = pg_error("INSERT INTO filter_accounts VALUES (#{conn.escape_literal(PG_ERROR_SENTINEL)})")
    expect(error.result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)).to include(PG_ERROR_SENTINEL)

    expect(filter.to_egress(error, step: "9b")).to eq(line(step: "9b", rule: "internal_error", sqlstate: "23505"))
  end

  it "filters a check violation, whose DETAIL holds the row" do
    error = pg_error("INSERT INTO filter_accounts VALUES (#{conn.escape_literal("#{PG_ERROR_SENTINEL}-bad")})")
    expect(error.result.error_field(PG::Result::PG_DIAG_MESSAGE_DETAIL)).to include(PG_ERROR_SENTINEL)

    expect(filter.to_egress(error, step: "10b")).to eq(line(step: "10b", rule: "internal_error", sqlstate: "23514"))
  end

  it "filters a unique violation raised inside the guard" do
    out = StringIO.new

    status = filter.guard(step: "9b", out:) do
      conn.exec_params("INSERT INTO filter_accounts VALUES ($1)", [PG_ERROR_SENTINEL])
    end

    expect(status).to eq(Quaack::Enclave::ErrorFilter::EX_SOFTWARE)
    expect(out.string).to eq("#{line(step: "9b", rule: "internal_error", sqlstate: "23505")}\n")
  end

  it "filters a connection error, which has no result" do
    params = test_database.connection_params.merge(dbname: PG_ERROR_SENTINEL)
    error = begin
      PG.connect(**params)
    rescue PG::Error => e
      e
    end
    expect(error.message).to include(PG_ERROR_SENTINEL)

    expect(filter.to_egress(error, step: "2")).to eq(line(step: "2", rule: "internal_error"))
  end

  describe ".drop_notices" do
    before do
      conn.exec(<<~SQL)
        CREATE FUNCTION filter_notice() RETURNS int LANGUAGE plpgsql STABLE AS $$
        BEGIN
          RAISE NOTICE 'notice %', (SELECT ssn FROM filter_accounts LIMIT 1);
          RAISE WARNING 'warning %', (SELECT ssn FROM filter_accounts LIMIT 1);
          RETURN 1;
        END $$
      SQL
    end

    # A child process connects and calls the function, so libpq's default
    # notice handling, which writes to the process's stderr, can be seen.
    def noisy_child(drop:)
      run_ruby("-I", File.join(GEM_ROOT, "lib"), "-e", <<~RUBY, JSON.generate(test_database.connection_params))
        require "json"
        require "pg"
        require "quaack/enclave/error_filter"
        conn = PG.connect(**JSON.parse(ARGV[0], symbolize_names: true))
        #{"Quaack::Enclave::ErrorFilter.drop_notices(conn)" if drop}
        print conn.exec("SELECT filter_notice()").getvalue(0, 0)
        conn.close
      RUBY
    end

    it "sees the notices on stderr without it, so the check works" do
      _out, err, status = noisy_child(drop: false)

      expect(status).to be_success
      expect(err).to include("notice #{PG_ERROR_SENTINEL}").and include("warning #{PG_ERROR_SENTINEL}")
    end

    it "drops every notice, so its values reach neither stderr nor stdout" do
      out, err, status = noisy_child(drop: true)

      expect(status).to be_success, "stderr was #{err}"
      expect(out).to eq("1")
      expect(err).not_to include(PG_ERROR_SENTINEL)
      expect(err).to eq("")
    end

    it "returns the connection it was given" do
      expect(filter.drop_notices(conn)).to be(conn)
    end
  end
end
