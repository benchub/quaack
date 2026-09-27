SELECT date_trunc('day', created_at) AS day, count(*) AS orders, sum(total_cents) AS total
FROM public.orders
WHERE created_at >= '2025-03-01 00:00:00'
  AND created_at < timestamptz '2025-03-01 00:00:00' + interval '1 month'
GROUP BY date_trunc('day', created_at)
ORDER BY 1;
