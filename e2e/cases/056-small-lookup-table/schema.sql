CREATE TABLE public.countries (
    code  text PRIMARY KEY,
    name  text NOT NULL
);

INSERT INTO public.countries (code, name)
SELECT 'C' || lpad(i::text, 3, '0'), 'Country ' || i
FROM generate_series(1, 250) AS i;
VACUUM ANALYZE;
