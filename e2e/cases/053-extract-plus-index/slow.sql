SELECT count(*) AS orders, sum(total_cents) AS total
FROM public.orders
WHERE extract(year FROM created_at) = 2025
  AND extract(month FROM created_at) = 7;
