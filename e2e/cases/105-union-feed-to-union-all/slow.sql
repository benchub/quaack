SELECT feed.kind, feed.id, feed.created_at
FROM (
    SELECT 'post' AS kind, posts.id, posts.group_id, posts.created_at FROM public.posts
    UNION
    SELECT 'comment', comments.id, comments.group_id, comments.created_at FROM public.comments
) AS feed
WHERE feed.group_id = 7
ORDER BY feed.created_at DESC
LIMIT 20;
