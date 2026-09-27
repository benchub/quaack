SELECT id, sku, name, price_cents
FROM public.catalog
WHERE price_cents BETWEEN SYMMETRIC 45200 AND 45000
  AND category NOT IN ('toys', 'garden')
  AND name NOT LIKE '%refurb%'
  AND sku NOT BETWEEN 'QRT' AND 'QRU'
  AND id NOT BETWEEN SYMMETRIC 100 AND 1
  AND category <> ALL (ARRAY['returns']);
