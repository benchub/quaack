CREATE TABLE public.messages (
    id          bigint PRIMARY KEY,
    tenant_id   integer NOT NULL,
    thread_id   integer NOT NULL,
    sent_at     timestamptz NOT NULL,
    body        text NOT NULL
);

-- 10 tenants, 50,000 threads of 12 messages each.
INSERT INTO public.messages (id, tenant_id, thread_id, sent_at, body)
SELECT i, 1 + ((i - 1) / 12) % 10, 1 + (i - 1) / 12,
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute', repeat('b', 80)
FROM generate_series(1, 600000) AS i;

CREATE INDEX messages_tenant_id_idx ON public.messages (tenant_id);
VACUUM ANALYZE;
