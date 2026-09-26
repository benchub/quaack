CREATE TABLE public.posts (
    id          bigint PRIMARY KEY,
    author_id   integer NOT NULL,
    title       text NOT NULL,
    body        text NOT NULL,
    created_at  timestamptz NOT NULL
);

-- 200 authors with 2,500 posts each.
INSERT INTO public.posts (id, author_id, title, body, created_at)
SELECT i, 1 + i % 200, 'Post ' || i, repeat('lorem ipsum ', 20),
       timestamptz '2024-01-01 00:00:00+00' + i * interval '3 minutes'
FROM generate_series(1, 500000) AS i;

CREATE INDEX posts_author_id_idx ON public.posts (author_id);
VACUUM ANALYZE;
