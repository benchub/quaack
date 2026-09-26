SELECT customer_id, count(*) AS orders, sum(total_cents) AS total
FROM public.orders
WHERE customer_id = 4242
GROUP BY customer_id
HAVING sum(total_cents) > 0;
