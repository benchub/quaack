CREATE TABLE public.tickets (
    id          bigint PRIMARY KEY,
    tenant_id   integer NOT NULL,
    status      text NOT NULL,
    subject     text NOT NULL
);

INSERT INTO public.tickets (id, tenant_id, status, subject)
SELECT i, 1 + i % 200, (ARRAY['open', 'pending', 'solved', 'closed'])[1 + (i / 200) % 4],
       'Ticket ' || i || repeat(' ', 60)
FROM generate_series(1, 500000) AS i;
VACUUM ANALYZE;
