SELECT id, price_cents, zip
FROM public.homes
WHERE price_cents BETWEEN 45000000 AND 45010000;
