SELECT id, email
FROM public.customers
WHERE email SIMILAR TO 'customer(1|2)%@example.com';
