SELECT d.n, d.day, count(o.id) AS orders
FROM generate_series(timestamptz '2025-03-01 00:00:00+00', timestamptz '2025-03-07 00:00:00+00', interval '1 day')
     WITH ORDINALITY AS d(day, n)
LEFT JOIN public.orders o ON o.created_at >= d.day AND o.created_at < d.day + interval '1 day'
GROUP BY d.n, d.day
ORDER BY d.n;
