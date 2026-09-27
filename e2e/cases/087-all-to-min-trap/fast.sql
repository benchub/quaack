SELECT p.id, p.price_cents
FROM public.items p
WHERE p.id <= 2000
  AND p.price_cents < (SELECT min(c.price_cents) FROM public.competitor_prices c WHERE c.item_id = p.id);
