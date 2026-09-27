SELECT o.id, o.created_at
FROM public.orders o
CROSS JOIN (SELECT max(created_at) AS latest FROM public.orders) m
WHERE o.created_at > m.latest - interval '1 hour';
