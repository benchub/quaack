SELECT id, created_at
FROM public.orders
WHERE (created_at, id) < ('2025-06-01 00:00:00+00', 250000)
ORDER BY created_at DESC, id DESC
LIMIT 50;
