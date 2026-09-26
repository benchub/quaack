CREATE TABLE public.homes (
    id           bigint PRIMARY KEY,
    price_cents  bigint NOT NULL,
    zip          text NOT NULL,
    sqft         integer NOT NULL
);

INSERT INTO public.homes (id, price_cents, zip, sqft)
SELECT i, 10000000 + (i::bigint * 7919) % 90000000, lpad((i % 99999)::text, 5, '0'), 500 + i % 4000
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
