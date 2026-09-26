CREATE TABLE public.categories (
    id         bigint PRIMARY KEY,
    parent_id  bigint REFERENCES public.categories (id),
    name       text NOT NULL
);

-- 2,000 roots. Node i > 2000 hangs under i / 10, so root r (200 <= r <= 2000)
-- has 10 children and 100 grandchildren.
INSERT INTO public.categories (id, parent_id, name)
SELECT i, CASE WHEN i <= 2000 THEN NULL ELSE i / 10 END, 'Category ' || i
FROM generate_series(1, 200000) AS i;
VACUUM ANALYZE;
