SELECT id, email, name
FROM public.users
WHERE lower(email) = 'user123456@example.com';
