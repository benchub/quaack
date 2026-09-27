-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.articles (
    id     bigint PRIMARY KEY,
    title  text NOT NULL,
    tags   text[] NOT NULL
);

-- The first tag is 'postgres' for 1 in 500 articles.
INSERT INTO public.articles (id, title, tags)
SELECT i, 'Article ' || i,
       ARRAY[CASE WHEN i % 500 = 0 THEN 'postgres' ELSE 'topic' || (i % 97) END, 'tag' || (i % 13), 'tag' || (i % 7)]
FROM generate_series(1, 300000) AS i;

VACUUM ANALYZE;
