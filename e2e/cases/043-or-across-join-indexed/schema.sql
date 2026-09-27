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

CREATE TABLE public.orders (
    id               bigint PRIMARY KEY,
    customer_id      bigint NOT NULL REFERENCES public.customers (id),
    status           text NOT NULL,
    tracking_number  text,
    total_cents      integer NOT NULL CHECK (total_cents >= 0),
    created_at       timestamptz NOT NULL
);

-- 7919 is prime and coprime to 50,000: 10 orders per customer, spread out.
-- Each customer has one order in every block of 50,000 ids. The newest block
-- is pending and one older block was cancelled; those have no tracking number.
INSERT INTO public.orders (id, customer_id, status, tracking_number, total_cents, created_at)
SELECT i,
       1 + (i::bigint * 7919) % 50000,
       CASE WHEN i > 450000 THEN 'pending' WHEN i / 50000 = 3 THEN 'cancelled' ELSE 'shipped' END,
       CASE WHEN i > 450000 OR i / 50000 = 3 THEN NULL ELSE 'TRK' || lpad(i::text, 10, '0') END,
       500 + (i * 37) % 20000,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;

CREATE INDEX orders_customer_id_idx ON public.orders (customer_id);
CREATE INDEX orders_tracking_idx ON public.orders (tracking_number);

VACUUM ANALYZE;
