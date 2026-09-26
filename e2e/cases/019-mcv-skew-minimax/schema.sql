CREATE TABLE public.audit_log (
    id          bigint PRIMARY KEY,
    tenant_id   integer NOT NULL,
    action      text NOT NULL,
    happened_at timestamptz NOT NULL
);

-- Tenant 1 owns 60% of the rows. The other 40% spread over 2,000 tenants.
INSERT INTO public.audit_log (id, tenant_id, action, happened_at)
SELECT i, CASE WHEN i % 5 < 3 THEN 1 ELSE 2 + i % 2000 END,
       (ARRAY['create', 'update', 'delete'])[1 + i % 3],
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
