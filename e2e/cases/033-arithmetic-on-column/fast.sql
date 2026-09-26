SELECT id, amount_cents, merchant_id
FROM public.charges
WHERE amount_cents >= 437 * 100
  AND amount_cents < (437 + 1) * 100;
