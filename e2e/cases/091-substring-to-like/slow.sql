SELECT id, sku, position('-' IN sku) AS dash_at,
       overlay(card PLACING '************' FROM 1 FOR 12) AS masked,
       trim(BOTH ' ' FROM code) AS code, trim(LEADING '0' FROM trim(code)) AS code_number,
       trim(TRAILING ' ' FROM code) AS padded_code
FROM public.parts
WHERE substring(sku FROM 1 FOR 7) = 'ABX-001';
