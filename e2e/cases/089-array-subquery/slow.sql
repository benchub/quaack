SELECT a.id, a.title,
       ARRAY(SELECT c.body FROM public.comments c WHERE c.article_id = a.id ORDER BY c.id) AS comments
FROM public.articles a
WHERE a.id IN (10, 20, 30);
