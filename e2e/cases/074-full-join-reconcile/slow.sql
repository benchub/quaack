SELECT COALESCE(b.ref, k.ref) AS ref, b.amount AS bank, k.amount AS book
FROM public.bank_rows b
FULL JOIN public.book_rows k ON k.ref = b.ref AND k.batch_id = b.batch_id
WHERE COALESCE(b.batch_id, k.batch_id) = 42
  AND b.amount IS DISTINCT FROM k.amount;
