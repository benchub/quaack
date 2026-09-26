SELECT customer_id, id, created_at
FROM (
    SELECT o.customer_id, o.id, o.created_at,
           row_number() OVER (PARTITION BY o.customer_id ORDER BY o.created_at DESC, o.id DESC) AS rn
    FROM public.orders o
    JOIN public.customers c ON c.id = o.customer_id
    WHERE c.tier = 'gold'
) ranked
WHERE rn <= 3;
