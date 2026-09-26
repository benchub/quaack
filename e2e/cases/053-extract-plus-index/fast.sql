SELECT count(*) AS orders, sum(total_cents) AS total
FROM public.orders
WHERE created_at >= make_timestamptz(2025, 7, 1, 0, 0, 0)
  AND created_at < make_timestamptz(2025, 7, 1, 0, 0, 0) + interval '1 month';
