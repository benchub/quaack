SELECT o.id, o.created_at, o.status, o.total_cents, c.email
FROM public.orders o
JOIN public.customers c ON c.id = o.customer_id
WHERE c.email = 'customer4242@example.com'
UNION
SELECT o.id, o.created_at, o.status, o.total_cents, c.email
FROM public.orders o
JOIN public.customers c ON c.id = o.customer_id
WHERE o.tracking_number = 'TRK0000123456'
ORDER BY created_at DESC, id;
