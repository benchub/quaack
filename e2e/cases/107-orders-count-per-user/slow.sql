SELECT COUNT(*) AS count_all, users.id AS users_id, users.email AS users_email, users.name AS users_name
FROM public.users
INNER JOIN public.orders ON orders.user_id = users.id
WHERE orders.status = 'paid'
GROUP BY users.id, users.email, users.name
