SELECT id, created_at AT LOCAL AS server_time
FROM public.orders
WHERE (created_at AT TIME ZONE 'America/New_York')::date = '2025-03-15';
