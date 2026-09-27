SELECT id, customer_id,
       CASE WHEN total_cents > 10000 THEN 'large' ELSE 'small' END AS size
FROM orders
WHERE customer_id = ANY ('{4242, 31337, 777}'::bigint[]);
