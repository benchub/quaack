SELECT customer_id, count(*) AS tracked
FROM public.orders
WHERE customer_id IN (4242, 31337)
GROUP BY customer_id;
