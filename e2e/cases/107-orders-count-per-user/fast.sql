SELECT quaack_pre_1.a_1 AS count_all, users.id AS users_id, users.email AS users_email, users.name AS users_name
FROM public.users
JOIN (SELECT orders.user_id, count(*) AS a_1
      FROM public.orders
      WHERE orders.status = 'paid'
      GROUP BY orders.user_id) quaack_pre_1
  ON quaack_pre_1.user_id = users.id
