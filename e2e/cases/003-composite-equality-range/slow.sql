SELECT id, kind, created_at
FROM public.events
WHERE account_id = 17
  AND created_at >= '2025-06-01 00:00:00+00'
  AND created_at < '2025-06-08 00:00:00+00'
ORDER BY created_at, id;
