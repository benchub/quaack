WITH averages AS (
    SELECT sensor_id, avg(value) AS avg_value
    FROM public.samples
    GROUP BY sensor_id
)
SELECT s.id, s.value - a.avg_value AS delta
FROM public.samples s
JOIN averages a ON a.sensor_id = s.sensor_id
WHERE s.batch >= 380;
