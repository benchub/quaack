-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.events (
    id          bigint PRIMARY KEY,
    account_id  integer NOT NULL,
    kind        text NOT NULL,
    created_at  timestamptz NOT NULL,
    detail      text NOT NULL
);

INSERT INTO public.events (id, account_id, kind, created_at, detail)
SELECT i, 1 + i % 1000, (ARRAY['login', 'view', 'click', 'purchase'])[1 + (i / 1000) % 4],
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute', repeat('x', 80)
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
