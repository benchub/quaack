SELECT id, amount_cents, merchant_id
FROM public.charges
WHERE amount_cents / 100 = 437;
