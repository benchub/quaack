SELECT id, created_at, status, total_cents
FROM public.orders
WHERE customer_id = 4242
ORDER BY created_at DESC, id;
