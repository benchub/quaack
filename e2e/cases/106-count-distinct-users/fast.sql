SELECT d_1.course_id, count(d_1.user_id_1) AS active_users
FROM (SELECT DISTINCT events.course_id, events.user_id AS user_id_1
      FROM public.events
      WHERE events.kind = 'page_view') d_1
GROUP BY d_1.course_id
