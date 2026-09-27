SELECT count(*) AS orders, sum(total_cents) AS total
FROM public.orders
WHERE status = 'shipped';
