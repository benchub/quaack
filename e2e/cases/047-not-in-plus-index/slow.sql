SELECT c.id, c.email
FROM public.customers c
WHERE c.tier = 'gold' AND c.region = 'apac'
  AND c.id NOT IN (SELECT o.customer_id FROM public.orders o);
