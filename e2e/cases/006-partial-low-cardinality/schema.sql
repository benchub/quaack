-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.jobs (
    id          bigint PRIMARY KEY,
    status      text NOT NULL,
    queue       text NOT NULL,
    queued_at   timestamptz NOT NULL,
    payload     text NOT NULL
);

-- 96% done, 3% queued, 1% failed.
INSERT INTO public.jobs (id, status, queue, queued_at, payload)
SELECT i,
       CASE WHEN i % 100 = 0 THEN 'failed' WHEN i % 100 < 4 THEN 'queued' ELSE 'done' END,
       (ARRAY['mail', 'billing', 'export'])[1 + i % 3],
       timestamptz '2025-01-01 00:00:00+00' + i * interval '30 seconds',
       repeat('p', 60)
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
