-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.shipments (
    id          bigint PRIMARY KEY,
    carrier     text NOT NULL,
    order_ref   text NOT NULL,
    shipped_at  timestamptz
);

INSERT INTO public.shipments (id, carrier, order_ref, shipped_at)
SELECT i, (ARRAY['ups', 'dhl', 'fedex', 'usps'])[1 + i % 4], 'ORD-' || i,
       CASE WHEN i % 200 = 1 THEN NULL
            ELSE timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute' END
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
