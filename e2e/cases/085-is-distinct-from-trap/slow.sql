SELECT count(*) AS other_issues
FROM public.issues
WHERE team_id IS DISTINCT FROM 7;
