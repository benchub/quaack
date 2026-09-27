SELECT id, total_cents, created_at
FROM public.orders
WHERE created_at >= '2025-06-07 09:19:00+00'
  AND customer_id = 4242;
