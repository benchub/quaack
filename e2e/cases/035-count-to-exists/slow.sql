SELECT c.id, c.email
FROM public.customers c
WHERE c.tier = 'gold'
  AND (SELECT count(*) FROM public.orders o
       WHERE o.customer_id = c.id AND o.status = 'shipped') > 0;
