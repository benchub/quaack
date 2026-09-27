-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.products (
    id          bigint PRIMARY KEY,
    sku         text NOT NULL,
    name        text NOT NULL,
    price_cents integer NOT NULL
);

INSERT INTO public.products (id, sku, name, price_cents)
SELECT i,
       (ARRAY['ABX', 'QRT', 'ZMN', 'KLP'])[1 + i % 4] || '-' || lpad(i::text, 7, '0'),
       'Product ' || i,
       100 + (i * 7) % 90000
FROM generate_series(1, 400000) AS i;

VACUUM ANALYZE;
