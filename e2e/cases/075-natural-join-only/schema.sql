-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.event_kinds (
    kind_code  text PRIMARY KEY,
    label      text NOT NULL
);

INSERT INTO public.event_kinds VALUES ('lg', 'Login'), ('vw', 'View'), ('ck', 'Click'), ('pu', 'Purchase');

CREATE TABLE public.events (
    id           bigint PRIMARY KEY,
    account_id   integer NOT NULL,
    kind_code    text NOT NULL,
    happened_at  timestamptz NOT NULL
);

-- Last year's events live in a child table.
CREATE TABLE public.events_2024 () INHERITS (public.events);

INSERT INTO public.events (id, account_id, kind_code, happened_at)
SELECT i, 1 + i % 1000, (ARRAY['lg', 'vw', 'ck', 'pu'])[1 + (i / 1000) % 4],
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 400000) AS i;

INSERT INTO public.events_2024 (id, account_id, kind_code, happened_at)
SELECT 1000000 + i, 1 + i % 1000, 'vw', timestamptz '2024-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 100000) AS i;
VACUUM ANALYZE;
