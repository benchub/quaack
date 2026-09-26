SELECT e.id, e.name
FROM public.employees e
WHERE NOT EXISTS (SELECT 1 FROM public.employees m WHERE m.manager_id = e.id)
  AND e.id < 1000;
