SELECT id, name
FROM public.companies
WHERE name COLLATE "C" LIKE 'Acme 12%'
ORDER BY name COLLATE "C";
