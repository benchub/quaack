SELECT user_id, count(*) AS sessions, sum(pages) AS pages
FROM public.sessions
WHERE started_at >= current_date - 1
GROUP BY user_id;
