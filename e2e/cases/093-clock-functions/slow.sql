SELECT id, user_id, due_at, localtimestamp::date AS today
FROM public.reminders
WHERE due_at >= date_trunc('day', now())
  AND due_at < date_trunc('day', current_timestamp) + interval '1 day';
