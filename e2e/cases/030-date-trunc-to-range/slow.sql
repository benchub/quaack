SELECT date_trunc('day', created_at) AS day, count(*) AS orders, sum(total_cents) AS total
FROM public.orders
WHERE date_trunc('month', created_at) = '2025-03-01 00:00:00+00'
GROUP BY date_trunc('day', created_at)
ORDER BY 1;
