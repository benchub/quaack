SELECT id FROM public.customers WHERE tier = 'gold' AND region = 'apac'
EXCEPT
SELECT customer_id FROM public.orders WHERE total_cents > 20000;
