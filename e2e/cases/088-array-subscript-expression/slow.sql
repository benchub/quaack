SELECT id, title, tags[1:2] AS top_tags
FROM public.articles
WHERE tags[1] = 'postgres';
