SELECT id, concat_ws(' ', VARIADIC ARRAY[first_name, last_name]) AS full_name
FROM public.people
WHERE signed_up_at >= timestamptz '2025-10-01 00:00:00+00' - make_interval(days => 3);
