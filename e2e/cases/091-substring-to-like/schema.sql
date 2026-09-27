CREATE TABLE public.parts (
    id    bigint PRIMARY KEY,
    sku   text NOT NULL,
    card  text NOT NULL,
    code  text NOT NULL
);

INSERT INTO public.parts (id, sku, card, code)
SELECT i, (ARRAY['ABX', 'QRT', 'ZMN', 'KLP'])[1 + i % 4] || '-' || lpad(i::text, 7, '0'),
       lpad(((i::bigint * 7919) % 10000000000000000)::text, 16, '4'),
       ' ' || lpad((i % 5000)::text, 6, '0') || ' '
FROM generate_series(1, 400000) AS i;

CREATE INDEX parts_sku_pattern_idx ON public.parts (sku text_pattern_ops);
VACUUM ANALYZE;
