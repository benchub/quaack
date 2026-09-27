CREATE TABLE public.items (
    id           bigint PRIMARY KEY,
    name         text NOT NULL,
    price_cents  integer NOT NULL
);

CREATE TABLE public.competitor_prices (
    id           bigint PRIMARY KEY,
    item_id      bigint NOT NULL REFERENCES public.items (id),
    price_cents  integer NOT NULL
);

INSERT INTO public.items (id, name, price_cents)
SELECT i, 'Item ' || i, 1000 + (i * 37) % 9000 FROM generate_series(1, 20000) AS i;

-- Items divisible by 4 have no competitor prices.
INSERT INTO public.competitor_prices (id, item_id, price_cents)
SELECT j, 1 + (j - 1) / 5, 1000 + (j * 53) % 9000
FROM generate_series(1, 100000) AS j
WHERE (1 + (j - 1) / 5) % 4 <> 0;

CREATE INDEX competitor_prices_item_idx ON public.competitor_prices (item_id);
VACUUM ANALYZE;
