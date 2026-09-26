SELECT o.id, o.customer_id, o.total_cents
FROM public.orders o
WHERE o.created_at >= '2025-12-10 00:00:00+00'
  AND o.total_cents > (SELECT avg(o2.total_cents)
                       FROM public.orders o2
                       WHERE o2.customer_id = o.customer_id);
