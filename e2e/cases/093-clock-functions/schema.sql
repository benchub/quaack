CREATE TABLE public.reminders (
    id       bigint PRIMARY KEY,
    user_id  integer NOT NULL,
    due_at   timestamptz NOT NULL
);

-- About 50 days either side of the load date.
INSERT INTO public.reminders (id, user_id, due_at)
SELECT i, i % 30000, current_date + (i - 250000) * interval '17 seconds'
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
