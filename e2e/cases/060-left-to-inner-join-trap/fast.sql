SELECT c.id, count(o.id) AS orders
FROM public.customers c
JOIN public.orders o ON o.customer_id = c.id
WHERE c.tier = 'gold'
GROUP BY c.id;
