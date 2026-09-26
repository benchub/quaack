SELECT DISTINCT ON (device_id) device_id, reported_at, battery
FROM public.telemetry
WHERE device_id IN (10, 20, 30, 40, 50)
ORDER BY device_id, reported_at DESC;
