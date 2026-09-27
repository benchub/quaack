SELECT p.category, sum(oi.quantity) AS units
FROM public.orders o
JOIN public.order_items oi ON oi.order_id = o.id
JOIN public.products p ON p.id = oi.product_id
WHERE o.created_at >= '2025-12-13 00:00:00+00'
GROUP BY p.category;
