CREATE TABLE public.sessions (
    id          bigint PRIMARY KEY,
    user_id     integer NOT NULL,
    started_at  timestamptz NOT NULL,
    pages       integer NOT NULL
);

-- About 60 days of sessions that end at the start of today. Relative to
-- the load date, so the query always finds rows.
INSERT INTO public.sessions (id, user_id, started_at, pages)
SELECT i, (i * 7) % 50000, current_date - i * interval '10 seconds' - interval '1 second', 1 + i % 30
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
