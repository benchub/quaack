CREATE TABLE public.companies (
    id    bigint PRIMARY KEY,
    name  text NOT NULL
);

INSERT INTO public.companies (id, name)
SELECT i, (ARRAY['Acme', 'Globex', 'Initech', 'Umbrella'])[1 + i % 4] || ' ' || i
FROM generate_series(1, 400000) AS i;

-- In the database's en_US.utf8 collation, which can't serve LIKE.
CREATE INDEX companies_name_idx ON public.companies (name);
VACUUM ANALYZE;
