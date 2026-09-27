CREATE TABLE public.catalog (
    id           bigint PRIMARY KEY,
    sku          text NOT NULL,
    category     text NOT NULL,
    name         text NOT NULL,
    price_cents  integer NOT NULL
);

INSERT INTO public.catalog (id, sku, category, name, price_cents)
SELECT i, (ARRAY['ABX', 'QRT', 'ZMN', 'KLP'])[1 + i % 4] || '-' || lpad(i::text, 7, '0'),
       (ARRAY['books', 'games', 'tools', 'garden', 'toys', 'returns'])[1 + i % 6],
       CASE WHEN i % 9 = 0 THEN 'Item ' || i || ' (refurb)' ELSE 'Item ' || i END,
       (i::bigint * 7919) % 100000
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
