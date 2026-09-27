SELECT o.id, o.created_at, c.email
FROM public.orders o
JOIN public.customers c ON c.id = o.customer_id
WHERE c.email = 'customer777@example.com'
   OR o.tracking_number = 'TRK0000300001';
