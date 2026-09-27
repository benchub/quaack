SELECT max(delivered_at) AS last_delivery
FROM public.deliveries
WHERE route_id = 21;
