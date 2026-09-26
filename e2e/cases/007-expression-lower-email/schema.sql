CREATE TABLE public.users (
    id          bigint PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    name        text NOT NULL,
    created_at  timestamptz NOT NULL
);

-- Emails keep the case people typed them in.
INSERT INTO public.users (id, email, name, created_at)
SELECT i,
       CASE WHEN i % 3 = 0 THEN 'User' || i || '@Example.com' ELSE 'user' || i || '@example.com' END,
       'User ' || i,
       timestamptz '2024-01-01 00:00:00+00' + i * interval '5 minutes'
FROM generate_series(1, 300000) AS i;
VACUUM ANALYZE;
