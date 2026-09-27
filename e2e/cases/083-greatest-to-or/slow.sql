SELECT id, GREATEST(updated_at, created_at) AS touched, LEAST(priority, 5) AS capped, NULLIF(note, '') AS note
FROM public.docs
WHERE GREATEST(updated_at, created_at) >= '2025-12-13 00:00:00+00';
