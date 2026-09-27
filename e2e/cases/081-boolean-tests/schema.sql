-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.todos (
    id           bigint PRIMARY KEY,
    assignee_id  integer NOT NULL,
    archived     boolean,
    urgent       boolean NOT NULL,
    perm         bit(4) NOT NULL,
    due_at       timestamptz,
    title        text NOT NULL
);

-- archived: NULL 10%, true 30%, false 60%. due_at is NULL 20% of the time.
INSERT INTO public.todos (id, assignee_id, archived, urgent, perm, due_at, title)
SELECT i, 1 + (i / 7) % 2000,
       CASE WHEN i % 10 = 0 THEN NULL WHEN i % 10 < 4 THEN true ELSE false END,
       i % 3 = 0,
       (i % 16)::bit(4),
       CASE WHEN i % 5 = 0 THEN NULL ELSE timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute' END,
       'Todo ' || i || repeat(' ', 40)
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
