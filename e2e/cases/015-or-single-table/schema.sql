CREATE TABLE public.accounts (
    id          bigint PRIMARY KEY,
    email       text NOT NULL UNIQUE,
    phone       text,
    name        text NOT NULL
);

INSERT INTO public.accounts (id, email, phone, name)
SELECT i, 'acct' || i || '@example.com',
       CASE WHEN i % 4 = 0 THEN NULL ELSE '+1555' || lpad(i::text, 7, '0') END,
       'Account ' || i
FROM generate_series(1, 400000) AS i;
VACUUM ANALYZE;
