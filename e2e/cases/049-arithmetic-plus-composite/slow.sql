SELECT id, amount_cents, created_at
FROM public.charges
WHERE merchant_id = 7 AND amount_cents / 100 = 437;
