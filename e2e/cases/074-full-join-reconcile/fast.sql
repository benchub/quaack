SELECT COALESCE(b.ref, k.ref) AS ref, b.amount AS bank, k.amount AS book
FROM (SELECT * FROM public.bank_rows WHERE batch_id = 42) b
FULL JOIN (SELECT * FROM public.book_rows WHERE batch_id = 42) k ON k.ref = b.ref
WHERE b.amount IS DISTINCT FROM k.amount;
