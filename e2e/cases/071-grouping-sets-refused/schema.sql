-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.customers (
    id          bigint PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    name        text NOT NULL,
    region      text NOT NULL,
    tier        text NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO public.customers (id, email, name, region, tier, created_at)
SELECT i,
       'customer' || i || '@example.com',
       'Customer ' || i,
       (ARRAY['na', 'eu', 'apac', 'latam'])[1 + i % 4],
       CASE WHEN i % 50 = 0 THEN 'gold' WHEN i % 5 = 0 THEN 'silver' ELSE 'standard' END,
       timestamptz '2024-01-01 00:00:00+00' + i * interval '10 minutes'
FROM generate_series(1, 50000) AS i;

VACUUM ANALYZE;
