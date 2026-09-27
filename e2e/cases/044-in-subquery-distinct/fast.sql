SELECT o.id, o.created_at, o.total_cents
FROM public.orders o
JOIN public.customers c ON c.id = o.customer_id
WHERE c.email = 'customer4242@example.com'
ORDER BY o.created_at;
