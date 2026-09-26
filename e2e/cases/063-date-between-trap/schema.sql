CREATE TABLE public.logins (
    id          bigint PRIMARY KEY,
    user_id     integer NOT NULL,
    logged_at   timestamptz NOT NULL
);

-- Every 7.5 seconds.
INSERT INTO public.logins (id, user_id, logged_at)
SELECT i, i % 10000, timestamptz '2025-01-01 00:00:00+00' + i * interval '7.5 seconds'
FROM generate_series(1, 400000) AS i;

-- And one login in the last half second of each of the first 30 days.
INSERT INTO public.logins (id, user_id, logged_at)
SELECT 400000 + d, 1, timestamptz '2025-01-01 23:59:59.5+00' + d * interval '1 day'
FROM generate_series(1, 30) AS d;

CREATE INDEX logins_logged_at_idx ON public.logins (logged_at);
VACUUM ANALYZE;
