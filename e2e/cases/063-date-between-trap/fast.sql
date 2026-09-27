SELECT count(*) AS logins
FROM public.logins
WHERE logged_at BETWEEN '2025-01-15 00:00:00' AND '2025-01-15 23:59:59';
