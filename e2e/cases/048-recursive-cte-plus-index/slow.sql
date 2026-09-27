WITH RECURSIVE tree AS (
    SELECT id, parent_id, id AS root_id, 1 AS depth
    FROM public.categories
    WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, t.root_id, t.depth + 1
    FROM public.categories c
    JOIN tree t ON c.parent_id = t.id
)
SELECT id, depth
FROM tree
WHERE root_id = 420;
