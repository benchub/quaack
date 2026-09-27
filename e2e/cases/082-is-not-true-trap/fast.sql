SELECT count(*) AS open_todos
FROM public.todos
WHERE assignee_id = 42 AND archived = false;
