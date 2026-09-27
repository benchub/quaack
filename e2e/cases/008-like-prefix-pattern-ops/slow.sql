SELECT id, sku, name
FROM public.products
WHERE sku LIKE 'ABX-00123%'
ORDER BY sku;
