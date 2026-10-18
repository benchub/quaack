-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.users (
    id    bigint PRIMARY KEY,
    name  text NOT NULL
);

INSERT INTO public.users (id, name)
SELECT i, 'User ' || i
FROM generate_series(1, 500) AS i;

CREATE TABLE public.posts (
    id          bigint PRIMARY KEY,
    user_id     bigint NOT NULL REFERENCES public.users (id),
    title       text NOT NULL,
    body        text NOT NULL,
    created_at  timestamptz NOT NULL
);

-- 400 posts per user, written round-robin, so each user's posts sit on 400
-- different heap pages.
INSERT INTO public.posts (id, user_id, title, body, created_at)
SELECT i,
       1 + i % 500,
       'Post ' || i,
       repeat(md5(i::text), 4),
       timestamptz '2025-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 200000) AS i;

CREATE INDEX posts_user_id ON public.posts (user_id);

VACUUM ANALYZE;
