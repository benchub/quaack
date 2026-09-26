CREATE TABLE public.ledger (
    id           bigint PRIMARY KEY,
    account_id   integer NOT NULL,
    amount       integer NOT NULL,
    posted_at    timestamptz NOT NULL UNIQUE
);

-- 5,000 accounts with 100 rows each.
INSERT INTO public.ledger (id, account_id, amount, posted_at)
SELECT i, 1 + i % 5000, ((i * 37) % 2001) - 1000,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
