SELECT id, created_at AT LOCAL AS server_time
FROM public.orders
WHERE created_at >= timestamp '2025-03-15' AT TIME ZONE 'America/New_York'
  AND created_at < (timestamp '2025-03-15' + interval '1 day') AT TIME ZONE 'America/New_York';
