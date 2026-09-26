SELECT id, sent_at, body
FROM public.messages
WHERE tenant_id = 3 AND thread_id = 12343
ORDER BY sent_at;
