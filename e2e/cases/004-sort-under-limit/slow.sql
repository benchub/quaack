SELECT id, title, created_at
FROM public.posts
WHERE author_id = 42
ORDER BY created_at DESC
LIMIT 20;
