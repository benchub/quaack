SELECT count(*) FILTER (WHERE status = 'pending') AS pending,
       count(*) FILTER (WHERE status = 'cancelled') AS cancelled,
       count(*) FILTER (WHERE status = 'shipped') AS shipped
FROM public.orders
WHERE created_at >= '2025-12-01 00:00:00+00';
