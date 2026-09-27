-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.payments (
    id              bigint PRIMARY KEY,
    merchant_id     integer NOT NULL,
    amount_cents    integer NOT NULL,
    currency        text NOT NULL,
    card_last4      text NOT NULL,
    memo            text NOT NULL,
    created_at      timestamptz NOT NULL
);

-- 200 merchants with 2,500 payments each, spread through the heap.
INSERT INTO public.payments (id, merchant_id, amount_cents, currency, card_last4, memo, created_at)
SELECT i, 1 + i % 200, 100 + (i * 13) % 50000, 'USD', lpad((i % 10000)::text, 4, '0'),
       repeat('m', 100), timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;

CREATE INDEX payments_merchant_id_idx ON public.payments (merchant_id);
VACUUM ANALYZE;
