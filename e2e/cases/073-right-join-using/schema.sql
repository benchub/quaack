-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.accounts (
    account_id  integer PRIMARY KEY,
    plan        text NOT NULL,
    name        text NOT NULL
);

-- 1 in 500 accounts is on the enterprise plan.
INSERT INTO public.accounts (account_id, plan, name)
SELECT i, CASE WHEN i % 500 = 0 THEN 'enterprise' WHEN i % 5 = 0 THEN 'pro' ELSE 'free' END, 'Account ' || i
FROM generate_series(1, 20000) AS i;

CREATE TABLE public.sessions (
    id          bigint PRIMARY KEY,
    account_id  integer NOT NULL REFERENCES public.accounts (account_id),
    started_at  timestamptz NOT NULL,
    pages       integer NOT NULL
);

-- Only accounts 1 to 18,000 have sessions, 25 each.
INSERT INTO public.sessions (id, account_id, started_at, pages)
SELECT i, 1 + (i::bigint * 7919) % 18000, timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute', 1 + i % 40
FROM generate_series(1, 450000) AS i;
VACUUM ANALYZE;
