SELECT id, customer_id, total_cents
FROM public.orders
WHERE created_at >= date '2025-03-15'
  AND created_at < date '2025-03-15' + 1;
