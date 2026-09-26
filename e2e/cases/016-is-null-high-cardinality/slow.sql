SELECT id, order_ref, created_at
FROM public.shipments
WHERE shipped_at IS NULL
ORDER BY created_at
LIMIT 100;
