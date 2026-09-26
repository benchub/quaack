SELECT id, created_at, total_cents
FROM public.orders
WHERE customer_id = CAST(4242.0 AS bigint);
