SELECT id, title
FROM public.tasks
WHERE COALESCE(status, 'new') = 'blocked';
