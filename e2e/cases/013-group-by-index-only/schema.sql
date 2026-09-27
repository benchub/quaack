-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.tickets (
    id          bigint PRIMARY KEY,
    tenant_id   integer NOT NULL,
    status      text NOT NULL,
    subject     text NOT NULL,
    opened_at   timestamptz NOT NULL
);

-- 200 tenants with 2,500 tickets each.
INSERT INTO public.tickets (id, tenant_id, status, subject, opened_at)
SELECT i, 1 + i % 200, (ARRAY['open', 'pending', 'solved', 'closed'])[1 + (i / 200) % 4],
       'Ticket ' || i || ' ' || repeat('s', 60),
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 500000) AS i;

CREATE INDEX tickets_tenant_id_idx ON public.tickets (tenant_id);
VACUUM ANALYZE;
