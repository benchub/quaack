SELECT s.id, s.value - (SELECT avg(s2.value) FROM public.samples s2 WHERE s2.sensor_id = s.sensor_id) AS delta
FROM public.samples s
WHERE s.batch >= 380;
