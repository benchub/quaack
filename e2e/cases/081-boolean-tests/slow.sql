SELECT id, due_at, perm & B'0001' = B'0001' AS can_read
FROM public.todos
WHERE assignee_id = 42
  AND archived IS NOT TRUE
  AND due_at IS NOT NULL
  AND urgent = true;
