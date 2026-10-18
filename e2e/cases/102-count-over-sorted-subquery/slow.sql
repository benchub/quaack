SELECT count(*)
FROM (
    SELECT posts.*
    FROM public.posts
    WHERE posts.user_id = 42
    ORDER BY posts.created_at DESC
) subquery_for_count;
