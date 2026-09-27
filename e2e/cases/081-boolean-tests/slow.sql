SELECT id, due_at, perm & B'0001' = B'0001' AS can_read,
       archived IS UNKNOWN AS unfiled, archived IS FALSE AS active, urgent IS TRUE AS flagged,
       archived IS NOT FALSE AS maybe_archived
FROM public.todos
WHERE assignee_id = 42
  AND archived IS NOT TRUE
  AND due_at IS NOT NULL
  AND urgent = true;
