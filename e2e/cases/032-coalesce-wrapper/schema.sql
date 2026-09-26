CREATE TABLE public.tasks (
    id          bigint PRIMARY KEY,
    status      text,
    title       text NOT NULL,
    updated_at  timestamptz NOT NULL
);

-- 80% done, 15% open, 1% blocked, 4% NULL. Nothing is 'new'.
INSERT INTO public.tasks (id, status, title, updated_at)
SELECT i, CASE WHEN i % 100 = 0 THEN 'blocked' WHEN i % 100 < 5 THEN NULL
               WHEN i % 100 < 20 THEN 'open' ELSE 'done' END,
       'Task ' || i || repeat(' ', 40), timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;

CREATE INDEX tasks_status_idx ON public.tasks (status);
VACUUM ANALYZE;
