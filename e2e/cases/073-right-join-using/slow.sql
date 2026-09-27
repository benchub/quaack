SELECT account_id, a.name, s.started_at
FROM public.sessions s
RIGHT JOIN public.accounts a USING (account_id)
WHERE a.plan = 'enterprise'
ORDER BY account_id, s.started_at;
