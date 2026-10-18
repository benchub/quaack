-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.groups (
    id    bigint PRIMARY KEY,
    name  text NOT NULL
);

INSERT INTO public.groups (id, name)
SELECT i, 'Group ' || i
FROM generate_series(1, 20) AS i;

-- One post every 2 minutes, spread over the 20 groups.
CREATE TABLE public.posts (
    id          bigint PRIMARY KEY,
    group_id    bigint NOT NULL REFERENCES public.groups (id),
    author_id   bigint NOT NULL,
    title       text NOT NULL,
    body        text NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO public.posts (id, group_id, author_id, title, body, created_at)
SELECT i,
       1 + i % 20,
       1 + i % 997,
       'Post ' || i,
       repeat('lorem ipsum ', 20),
       timestamptz '2025-01-01 00:00:00+00' + i * interval '2 minutes'
FROM generate_series(1, 200000) AS i;

-- Two comments on every post, in the post's group, 30 and 60 seconds after
-- it. No two posts or comments share a created_at.
CREATE TABLE public.comments (
    id          bigint PRIMARY KEY,
    post_id     bigint NOT NULL REFERENCES public.posts (id),
    group_id    bigint NOT NULL REFERENCES public.groups (id),
    author_id   bigint NOT NULL,
    body        text NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO public.comments (id, post_id, group_id, author_id, body, created_at)
SELECT i,
       1 + (i - 1) / 2,
       1 + (1 + (i - 1) / 2) % 20,
       1 + i % 991,
       repeat('dolor sit amet ', 10),
       timestamptz '2025-01-01 00:00:00+00' + (1 + (i - 1) / 2) * interval '2 minutes'
         + (1 + i % 2) * interval '30 seconds'
FROM generate_series(1, 400000) AS i;

-- The group feed's own indices.
CREATE INDEX posts_group_id_created_at_idx ON public.posts (group_id, created_at);
CREATE INDEX comments_group_id_created_at_idx ON public.comments (group_id, created_at);

VACUUM ANALYZE;
