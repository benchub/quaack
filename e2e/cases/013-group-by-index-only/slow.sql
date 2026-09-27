SELECT status, count(*) AS tickets
FROM public.tickets
WHERE tenant_id = 12
GROUP BY status;
