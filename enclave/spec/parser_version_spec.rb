# frozen_string_literal: true

require "quaack/enclave/parser_version"

RSpec.describe Quaack::Enclave::ParserVersion do
  it "takes the grammar's major version, 17, from pg_query itself" do
    expect(described_class::MAJOR).to eq(17)
  end

  it "names the grammar and the next version in the note" do
    expect(described_class::NOTE)
      .to eq("pg_query parses with the Postgres 17 grammar; " \
             "Postgres 18-only syntax isn't supported yet")
  end
end
