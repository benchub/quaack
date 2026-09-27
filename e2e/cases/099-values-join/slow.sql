SELECT v.sku, v.qty, p.price_cents * v.qty AS line_cents
FROM (VALUES ('ABX-0000100', 2), ('QRT-0000101', 1), ('ZMN-0000102', 5)) AS v(sku, qty)
JOIN public.products p ON p.sku = v.sku;
