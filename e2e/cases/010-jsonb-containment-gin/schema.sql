CREATE TABLE public.webhooks (
    id           bigint PRIMARY KEY,
    received_at  timestamptz NOT NULL,
    payload      jsonb NOT NULL
);

-- 1 in 500 events is a refund.
INSERT INTO public.webhooks (id, received_at, payload)
SELECT i,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '20 seconds',
       jsonb_build_object(
           'type', CASE WHEN i % 500 = 0 THEN 'refund' WHEN i % 3 = 0 THEN 'charge' ELSE 'ping' END,
           'account', 'acct_' || (i % 3000),
           'amount', (i * 17) % 100000)
FROM generate_series(1, 400000) AS i;
VACUUM ANALYZE;
