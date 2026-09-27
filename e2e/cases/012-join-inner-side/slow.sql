SELECT o.id AS order_id, o.created_at, p.name, oi.quantity
FROM public.orders o
JOIN public.order_items oi ON oi.order_id = o.id
JOIN public.products p ON p.id = oi.product_id
WHERE o.customer_id = 4242;
