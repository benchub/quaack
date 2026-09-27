-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.ledger (
    id           bigint PRIMARY KEY,
    account_id   integer NOT NULL,
    amount       integer NOT NULL,
    posted_at    timestamptz NOT NULL
);

INSERT INTO public.ledger (id, account_id, amount, posted_at)
SELECT i, 1 + i % 1000, ((i * 37) % 2001) - 1000,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
