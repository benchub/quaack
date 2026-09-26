SELECT id, email, phone, name
FROM public.accounts
WHERE email = 'acct1234@example.com' OR phone = '+15550200001';
