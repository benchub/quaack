-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.deliveries (
    id            bigint PRIMARY KEY,
    route_id      integer NOT NULL,
    delivered_at  timestamptz
);

-- Undelivered stops have a NULL delivered_at.
INSERT INTO public.deliveries (id, route_id, delivered_at)
SELECT i, 1 + i % 300,
       CASE WHEN i % 40 = 0 THEN NULL ELSE timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute' END
FROM generate_series(1, 300000) AS i;

CREATE INDEX deliveries_route_idx ON public.deliveries (route_id, delivered_at);
VACUUM ANALYZE;
