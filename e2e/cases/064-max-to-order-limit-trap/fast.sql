SELECT delivered_at AS last_delivery
FROM public.deliveries
WHERE route_id = 21
ORDER BY delivered_at DESC
LIMIT 1;
