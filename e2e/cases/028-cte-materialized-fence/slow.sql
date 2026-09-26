WITH recent AS MATERIALIZED (
    SELECT id, customer_id, total_cents, created_at
    FROM public.orders
    WHERE created_at >= '2025-06-01 00:00:00+00'
)
SELECT id, total_cents, created_at
FROM recent
WHERE customer_id = 4242;
