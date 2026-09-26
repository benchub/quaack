SELECT count(*) AS payments, sum(amount_cents) AS total_cents
FROM public.payments
WHERE merchant_id = 7;
