SELECT c.id, c.email
FROM public.customers c
WHERE c.tier = 'gold' AND c.region = 'apac'
  AND NOT EXISTS (SELECT 1 FROM public.orders o WHERE o.customer_id = c.id);
