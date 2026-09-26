SELECT o.id, o.created_at, o.total_cents
FROM public.orders o
WHERE o.created_at >= '2025-12-01 00:00:00+00';
