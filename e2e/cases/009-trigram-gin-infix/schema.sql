-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE EXTENSION pg_trgm;

CREATE TABLE public.contacts (
    id          bigint PRIMARY KEY,
    full_name   text NOT NULL,
    company     text NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO public.contacts (id, full_name, company, created_at)
SELECT i,
       (ARRAY['Ana', 'Ben', 'Chen', 'Dara', 'Eli', 'Farah', 'Gus', 'Hana'])[1 + i % 8] || ' ' ||
       (ARRAY['Smith', 'Okafor', 'Nguyen', 'Garcia', 'Kowalski', 'Haddad', 'Ito'])[1 + (i / 8) % 7] ||
       '-' || to_hex(i * 2654435761 % 4294967296),
       'Company ' || (i % 5000),
       timestamptz '2024-01-01 00:00:00+00' + i * interval '2 minutes'
FROM generate_series(1, 300000) AS i;
VACUUM ANALYZE;
