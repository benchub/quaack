SELECT e.id, e.name
FROM public.employees e
WHERE e.id NOT IN (SELECT m.manager_id FROM public.employees m)
  AND e.id < 1000;
