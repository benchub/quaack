SELECT count(*)
FROM (
    SELECT posts.*
    FROM public.posts
    WHERE posts.user_id = 42
) subquery_for_count;
