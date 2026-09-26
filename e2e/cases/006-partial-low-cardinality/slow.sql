SELECT id, queue, queued_at
FROM public.jobs
WHERE status = 'failed'
ORDER BY queued_at, id
LIMIT 50;
