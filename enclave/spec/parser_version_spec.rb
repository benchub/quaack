# frozen_string_literal: true

require "quaack/enclave/parser_version"

RSpec.describe Quaack::Enclave::ParserVersion do
  it "takes the grammar's major version from pg_query itself" do
    expect(described_class::MAJOR).to eq(PgQuery::PG_VERSION_NUM / 10_000)
  end

  it "names the grammar and the next version in the note" do
    expect(described_class::NOTE)
      .to eq("pg_query parses with the Postgres #{described_class::MAJOR} grammar; " \
             "Postgres #{described_class::MAJOR + 1}-only syntax isn't supported yet")
  end
end
