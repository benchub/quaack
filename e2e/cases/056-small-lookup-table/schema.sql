-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.countries (
    code  text PRIMARY KEY,
    name  text NOT NULL
);

INSERT INTO public.countries (code, name)
SELECT 'C' || lpad(i::text, 3, '0'), 'Country ' || i
FROM generate_series(1, 250) AS i;
VACUUM ANALYZE;
