SELECT action, count(*) AS n
FROM public.audit_log
WHERE tenant_id = 780
GROUP BY action;
