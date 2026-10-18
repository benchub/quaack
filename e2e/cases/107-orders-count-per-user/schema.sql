-- Statistics from every row, not ANALYZE's random sample, so plans and
-- block counts repeat from one load to the next.
SET default_statistics_target = 10000;

CREATE TABLE public.users (
    id          bigint PRIMARY KEY,
    email       text NOT NULL,
    name        text NOT NULL,
    bio         text NOT NULL,
    created_at  timestamptz NOT NULL
);

CREATE TABLE public.orders (
    id          bigint PRIMARY KEY,
    user_id     bigint NOT NULL REFERENCES public.users,
    total       numeric NOT NULL,
    status      text NOT NULL,
    created_at  timestamptz NOT NULL
);

-- 120,000 users, each with a short profile. The first 100,000 have orders.
INSERT INTO public.users (id, email, name, bio, created_at)
SELECT i,
       'user' || i || '@example.com',
       'User number ' || i,
       repeat('Likes long walks and short queries. ', 8),
       timestamptz '2024-01-01 00:00:00+00' + i * interval '1 minute'
FROM generate_series(1, 120000) AS i;

-- 3,000,000 orders, 30 for each of those users. Each user's orders share one
-- status: 75,000 users have only paid orders, and 25,000 only refunded ones.
INSERT INTO public.orders (id, user_id, total, status, created_at)
SELECT i,
       1 + (i::bigint * 7919) % 100000,
       (i % 500) + 0.99,
       (ARRAY['paid', 'paid', 'paid', 'refunded'])[1 + i % 4],
       timestamptz '2025-01-01 00:00:00+00' + i * interval '10 seconds'
FROM generate_series(1, 3000000) AS i;

VACUUM ANALYZE;
