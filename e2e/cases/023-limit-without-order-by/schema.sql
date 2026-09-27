-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.invoices (
    id           bigint PRIMARY KEY,
    customer_id  integer NOT NULL,
    status       text NOT NULL,
    due_date     date NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO public.invoices (id, customer_id, status, due_date, amount_cents)
SELECT i, 1 + i % 5000, CASE WHEN i % 7 = 0 THEN 'overdue' WHEN i % 3 = 0 THEN 'open' ELSE 'paid' END,
       date '2025-01-01' + (i % 365), 1000 + (i * 17) % 90000
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
