SELECT events.course_id, count(DISTINCT events.user_id) AS active_users
FROM public.events
WHERE events.kind = 'page_view'
GROUP BY events.course_id
