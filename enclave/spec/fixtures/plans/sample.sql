-- The sample schema and rows the plan fixtures were captured from. capture.rb
-- loads this file. It's a copy of spec/support/postgres/schema.sql and
-- data.sql from the test-harness branch (commit f292692), which hasn't landed
-- on main yet. Once it lands, capture.rb can load those files instead.

-- The sample schema, based on the README's orders and customers example.
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

-- Sample rows for schema.sql. Everything is computed from the row number,
-- not random(), so every run gets the same rows. The tables are small enough
-- that ANALYZE samples every row, so pg_stats comes out the same every run
-- too. It follows the shape of the README's 5a-5 example, not its exact
-- numbers:
--
-- - customers.name looks like PII: first name, last name, then the row
--   number, such as 'Ben Smith 1'. It's nearly unique (n_distinct -0.98),
--   with 2% NULLs. A prefix LIKE on it matches first names, not last names.
-- - customers.email looks like PII and is unique.
-- - orders.status is low-cardinality, with six values at 71%, 12%, 9%, 4%,
--   3%, and 1%. Its correlation is 0.53: the values repeat in a fixed
--   cycle through the table, so they're neither clustered nor random.
-- - orders.created_at rises with every row. The few minutes of jitter never
--   reorder rows, so its correlation is exactly 1.
-- - orders.total_cents is nearly unique and has no index, so tests can try a
--   hypothetical one on it.
--
-- For whoever captures plan fixtures from this data: it's small, so the
-- planner picks hash joins in memory. To get a nested loop, turn off
-- enable_hashjoin and enable_mergejoin. To get a hash join that spills into
-- several batches, set a low work_mem, such as 64kB.

INSERT INTO customers (name, email, created_at)
SELECT
  CASE WHEN i % 50 = 0 THEN NULL
       ELSE format('%s %s %s', first_names[1 + i % 8], last_names[1 + i / 8 % 10], i) END,
  format('%s.%s.%s@example.com', lower(first_names[1 + i % 8]), lower(last_names[1 + i / 8 % 10]), i),
  timestamptz '2025-01-01 00:00:00+00' + i * interval '3 hours'
FROM generate_series(1, 2000) AS i,
     (SELECT ARRAY['Ada', 'Ben', 'Chen', 'Dana', 'Eli', 'Fatima', 'Gus', 'Hana'] AS first_names,
             ARRAY['Smith', 'Jones', 'Garcia', 'Nguyen', 'Okafor', 'Silva', 'Kowalski', 'Haddad', 'Park', 'Ito']
               AS last_names) AS n;

INSERT INTO orders (customer_id, status, total_cents, created_at)
SELECT
  1 + i * 7 % 2000,
  CASE WHEN i * 37 % 100 < 71 THEN 'delivered'
       WHEN i * 37 % 100 < 83 THEN 'shipped'
       WHEN i * 37 % 100 < 92 THEN 'pending'
       WHEN i * 37 % 100 < 96 THEN 'cancelled'
       WHEN i * 37 % 100 < 99 THEN 'returned'
       ELSE 'failed' END,
  100 + i * 7907 % 50000,
  timestamptz '2026-01-01 00:00:00+00' + i * interval '10 minutes' + i * 7919 % 300 * interval '1 second'
FROM generate_series(1, 20000) AS i;
