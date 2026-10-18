-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.events (
    id          bigint PRIMARY KEY,
    course_id   bigint NOT NULL,
    user_id     bigint,
    kind        text NOT NULL,
    created_at  timestamptz NOT NULL
);

-- 1,500,000 events in 40 courses by 3,000 users, so each (course, user)
-- pair repeats many times. Every 97th event has no user.
INSERT INTO public.events (id, course_id, user_id, kind, created_at)
SELECT i,
       1 + i % 40,
       CASE WHEN i % 97 = 0 THEN NULL ELSE 1 + (i::bigint * 7919) % 3000 END,
       (ARRAY['page_view', 'page_view', 'page_view', 'submission', 'discussion'])[1 + i % 5],
       timestamptz '2025-01-01 00:00:00+00' + i * interval '15 seconds'
FROM generate_series(1, 1500000) AS i;

VACUUM ANALYZE;
