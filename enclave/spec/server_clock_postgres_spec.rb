# frozen_string_literal: true

require "quaack/enclave/server_clock"

RSpec.describe Quaack::Enclave::ServerClock do
  # Task 20261007-9: public's clock_timestamp(), stuck at the epoch, and
  # public's numeric * integer, which gives 0, ahead of pg_catalog's on the
  # search_path. The clock still reads the server's own time.
  it "reads the server's clock when public's clock_timestamp and * shadow pg_catalog's" do
    conn = test_database.connection
    conn.exec("SET search_path = public, pg_catalog")
    conn.exec("CREATE FUNCTION public.clock_timestamp() RETURNS pg_catalog.timestamptz " \
              "LANGUAGE sql AS $$ SELECT 'epoch'::pg_catalog.timestamptz $$")
    conn.exec("CREATE FUNCTION public.quaack_zero(pg_catalog.numeric, pg_catalog.int4) RETURNS pg_catalog.numeric " \
              "LANGUAGE sql AS $$ SELECT 0::pg_catalog.numeric $$")
    conn.exec("CREATE OPERATOR public.* (LEFTARG = pg_catalog.numeric, RIGHTARG = pg_catalog.int4, " \
              "FUNCTION = public.quaack_zero)")
    now = Float(conn.exec("SELECT pg_catalog.date_part('epoch', pg_catalog.now()) OPERATOR(pg_catalog.*) 1000")
                    .getvalue(0, 0))

    expect(described_class.ms(conn, "")).to be_within(60_000).of(now)
  end
end
