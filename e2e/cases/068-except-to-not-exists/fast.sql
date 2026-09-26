SELECT c.id FROM public.customers c
WHERE c.tier = 'gold' AND c.region = 'apac'
  AND NOT EXISTS (SELECT 1 FROM public.orders o
                  WHERE o.customer_id = c.id AND o.total_cents > 20000);
