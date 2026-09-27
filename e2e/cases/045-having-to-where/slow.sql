SELECT customer_id, count(*) AS orders, sum(total_cents) AS total
FROM public.orders
GROUP BY customer_id
HAVING customer_id = 4242 AND sum(total_cents) > 0;
