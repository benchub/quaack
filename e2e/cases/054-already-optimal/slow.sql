SELECT id, created_at, total_cents
FROM public.orders
WHERE customer_id = 4242
ORDER BY created_at DESC
LIMIT 5;
