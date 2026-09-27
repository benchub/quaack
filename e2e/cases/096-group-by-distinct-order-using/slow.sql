SELECT tenant_id, status, count(*) AS n
FROM public.tickets
WHERE tenant_id = 12
GROUP BY DISTINCT tenant_id, status
ORDER BY n USING >, status;
