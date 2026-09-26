-- Support search: orders by the customer's email or by a tracking number.
SELECT o.id, o.created_at, o.status, o.total_cents, c.email
FROM public.orders o
JOIN public.customers c ON c.id = o.customer_id
WHERE c.email = 'customer4242@example.com'
   OR o.tracking_number = 'TRK0000123456'
ORDER BY o.created_at DESC, o.id;
