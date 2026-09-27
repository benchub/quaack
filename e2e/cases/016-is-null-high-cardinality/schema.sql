-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.shipments (
    id          bigint PRIMARY KEY,
    order_ref   text NOT NULL,
    created_at  timestamptz NOT NULL,
    shipped_at  timestamptz
);

-- 1 in 200 shipments hasn't shipped yet.
INSERT INTO public.shipments (id, order_ref, created_at, shipped_at)
SELECT i, 'ORD-' || i,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute',
       CASE WHEN i % 200 = 0 THEN NULL
            ELSE timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute' + interval '2 days' END
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
