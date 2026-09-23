# frozen_string_literal: true

RSpec.describe "pg_query in the enclave" do
  # Runs in a child process, so it proves that loading the enclave gem makes
  # pg_query available, and that pg_query's native extension built on this
  # Ruby. In this process another spec might already have loaded it.
  it "is loaded by the enclave gem and parses a trivial SELECT" do
    code = <<~RUBY
      require "quaack/enclave"
      result = PgQuery.parse("SELECT 1")
      puts result.tree.stmts.size
      puts result.tree.stmts.first.stmt.node
      puts result.deparse
    RUBY
    out, err, status = run_ruby("-e", code)

    expect(out).to eq("1\nselect_stmt\nSELECT 1\n"), "stderr was #{err}"
    expect(status).to be_success
  end
end
