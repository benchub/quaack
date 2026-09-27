-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.people (
    id            bigint PRIMARY KEY,
    first_name    text NOT NULL,
    last_name     text NOT NULL,
    signed_up_at  timestamptz NOT NULL
);

INSERT INTO public.people (id, first_name, last_name, signed_up_at)
SELECT i, 'First' || (i % 900), 'Last' || (i % 7000), timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 400000) AS i;
VACUUM ANALYZE;
