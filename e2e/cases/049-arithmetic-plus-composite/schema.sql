CREATE TABLE public.charges (
    id            bigint PRIMARY KEY,
    amount_cents  integer NOT NULL CHECK (amount_cents >= 0),
    merchant_id   integer NOT NULL,
    created_at    timestamptz NOT NULL
);

INSERT INTO public.charges (id, amount_cents, merchant_id, created_at)
SELECT i, (i::bigint * 7919) % 100000, 1 + i % 30,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 600000) AS i;
VACUUM ANALYZE;
