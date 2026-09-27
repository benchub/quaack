-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.stock_moves (
    id          bigint PRIMARY KEY,
    product_id  integer NOT NULL,
    warehouse   text NOT NULL,
    delta       integer NOT NULL,
    moved_at    timestamptz NOT NULL
);

INSERT INTO public.stock_moves (id, product_id, warehouse, delta, moved_at)
SELECT i, 1 + (i::bigint * 7919) % 20000, (ARRAY['east', 'west', 'north'])[1 + i % 3], (i % 21) - 10,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
