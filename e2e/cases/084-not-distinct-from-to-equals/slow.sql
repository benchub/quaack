SELECT id, title
FROM public.issues
WHERE team_id IS NOT DISTINCT FROM 7;
