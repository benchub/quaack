SELECT orders.id AS t0_r0, orders.customer_id AS t0_r1, orders.status AS t0_r2,
       orders.tracking_number AS t0_r3, orders.total_cents AS t0_r4, orders.created_at AS t0_r5,
       customers.id AS t1_r0, customers.email AS t1_r1, customers.name AS t1_r2,
       customers.region AS t1_r3, customers.tier AS t1_r4, customers.created_at AS t1_r5
FROM public.orders
LEFT OUTER JOIN public.customers ON customers.id = orders.customer_id
WHERE orders.status = 'pending'
ORDER BY customers.name, orders.id ASC
LIMIT 25;
