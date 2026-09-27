SELECT id, order_ref, shipped_at
FROM public.shipments
WHERE carrier = 'dhl'
ORDER BY shipped_at DESC NULLS LAST, id DESC
LIMIT 20 OFFSET 40;
