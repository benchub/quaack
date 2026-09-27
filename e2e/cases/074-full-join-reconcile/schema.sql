CREATE TABLE public.bank_rows (
    id        bigint PRIMARY KEY,
    batch_id  integer NOT NULL,
    ref       text NOT NULL,
    amount    integer NOT NULL
);

CREATE TABLE public.book_rows (
    id        bigint PRIMARY KEY,
    batch_id  integer NOT NULL,
    ref       text NOT NULL,
    amount    integer NOT NULL
);

-- 2,000 batches of 100. The books miss 1 in 50 bank rows, disagree on
-- 1 in 37 amounts, and have extra rows of their own.
INSERT INTO public.bank_rows (id, batch_id, ref, amount)
SELECT i, i % 2000, 'R' || i, (i * 13) % 100000
FROM generate_series(1, 200000) AS i;

INSERT INTO public.book_rows (id, batch_id, ref, amount)
SELECT i, i % 2000, CASE WHEN i % 70 = 0 THEN 'X' || i ELSE 'R' || i END,
       (i * 13) % 100000 + CASE WHEN i % 37 = 0 THEN 1 ELSE 0 END
FROM generate_series(1, 200000) AS i
WHERE i % 50 <> 0;

CREATE INDEX bank_rows_batch_idx ON public.bank_rows (batch_id);
CREATE INDEX book_rows_batch_idx ON public.book_rows (batch_id);
VACUUM ANALYZE;
