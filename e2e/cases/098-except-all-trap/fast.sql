SELECT o.customer_id FROM public.orders o
WHERE o.customer_id <= 200 AND o.created_at >= '2025-06-01 00:00:00+00'
  AND NOT EXISTS (SELECT 1 FROM public.orders p
                  WHERE p.customer_id = o.customer_id AND p.status = 'pending');
