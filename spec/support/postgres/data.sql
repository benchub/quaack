-- Sample rows for schema.sql. Everything is computed from the row number,
-- not random(), so every run gets the same rows. The tables are small enough
-- that ANALYZE samples every row, so pg_stats comes out the same every run
-- too. The shape follows the README's 5a-5 example:
--
-- - customers.name looks like PII and is nearly unique, with 2% NULLs.
-- - customers.email looks like PII and is unique.
-- - orders.status is low-cardinality, with six values at 71%, 12%, 9%, 4%,
--   3%, and 1%, scattered through the table rather than clustered.
-- - orders.created_at rises with the row number, give or take a few
--   minutes, so its correlation is close to 1.
-- - orders.total_cents is nearly unique and has no index, so tests can try a
--   hypothetical one on it.

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
