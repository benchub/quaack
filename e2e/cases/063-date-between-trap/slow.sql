SELECT count(*) AS logins
FROM public.logins
WHERE logged_at::date = '2025-01-15';
