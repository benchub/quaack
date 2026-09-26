SELECT sensor_id, count(*) AS readings, sum(value) AS total
FROM public.readings
WHERE recorded_at >= '2025-01-10 00:00:00+00'
  AND recorded_at < '2025-01-10 01:00:00+00'
GROUP BY sensor_id;
