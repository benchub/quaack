# frozen_string_literal: true

require "quaack/enclave/schema_dump"

# schema_dump_postgres_spec.rb shows what a dump does with each kind of
# schema. This pins the names alone.
RSpec.describe Quaack::Enclave::SchemaDump do
  describe ".system_schema?" do
    it "takes pg_catalog, information_schema, and every other pg_ schema" do
      %w[pg_catalog pg_toast pg_temp_3 pg_toast_temp_3 information_schema].each do |name|
        expect(described_class.system_schema?(name)).to be(true), name
      end
    end

    # Schema names are case-sensitive, so "Information_Schema" is a user
    # schema of its own, and pgbouncer or pgaudit_log only starts with pg.
    it "leaves every other schema to the user" do
      %w[public pgbouncer pgaudit_log Information_Schema PG_toast pg].each do |name|
        expect(described_class.system_schema?(name)).to be(false), name
      end
    end
  end
end
