-- The sample schema, based on DESIGN.md's orders and customers example.
-- spec/support/test_postgres.rb loads it into both template databases:
-- arena's, which stays empty, and racetrack's, which also gets data.sql.

CREATE TABLE customers (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text,
  email text NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE UNIQUE INDEX customers_email_key ON customers (email);

CREATE TABLE orders (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  customer_id bigint NOT NULL REFERENCES customers (id),
  status text NOT NULL,
  total_cents integer NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE INDEX orders_customer_id_idx ON orders (customer_id);
CREATE INDEX orders_status_created_at_idx ON orders (status, created_at);
