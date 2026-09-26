SELECT o.id, o.created_at, o.total_cents
FROM public.orders o
WHERE o.customer_id IN (
    SELECT DISTINCT c.id FROM public.customers c WHERE c.email = 'customer4242@example.com'
)
ORDER BY o.created_at;
